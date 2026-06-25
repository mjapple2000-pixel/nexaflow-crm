import { createClient } from 'npm:@supabase/supabase-js@2';
import Stripe from 'npm:stripe@14';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
      apiVersion: '2024-06-20',
      httpClient: Stripe.createFetchHttpClient(),
    });

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    );

    // Verify JWT — this endpoint requires auth
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Get business_id for this user
    const { data: profile } = await supabase
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .maybeSingle();

    if (!profile?.business_id) {
      return new Response(JSON.stringify({ error: 'No business found' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const businessId = profile.business_id;

    // Get business details for pre-filling Stripe onboarding
    const { data: business } = await supabase
      .from('businesses')
      .select('business_name, business_email, business_phone')
      .eq('id', businessId)
      .maybeSingle();

    // Check if Connect account already exists for this business
    const { data: existing } = await supabase
      .from('stripe_connect_accounts')
      .select('id, stripe_account_id, onboarding_complete')
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .maybeSingle();

    let stripeAccountId: string;

    if (existing?.stripe_account_id) {
      // Account already exists — just generate a fresh onboarding link
      stripeAccountId = existing.stripe_account_id;
    } else {
      // Create a new Stripe Express account
      const account = await stripe.accounts.create({
        type: 'express',
        country: 'US',
        email: business?.business_email ?? undefined,
        business_type: 'company',
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
        business_profile: {
          name: business?.business_name ?? undefined,
        },
      });

      stripeAccountId = account.id;

      // Write to stripe_connect_accounts
      await supabase.from('stripe_connect_accounts').insert({
        business_id: businessId,
        stripe_account_id: stripeAccountId,
        onboarding_complete: false,
        charges_enabled: false,
        payouts_enabled: false,
        default_currency: 'usd',
      });

      // Mark onboarding started on businesses table
      await supabase
        .from('businesses')
        .update({ stripe_connect_onboarding_started_at: new Date().toISOString() })
        .eq('id', businessId);
    }

    // Generate hosted onboarding URL
    const platformUrl = 'https://nexaflow-crm.web.app';
    const accountLink = await stripe.accountLinks.create({
      account: stripeAccountId,
      refresh_url: `${platformUrl}/settings?section=payments&stripe=refresh`,
      return_url:  `${platformUrl}/settings?section=payments&stripe=success`,
      type: 'account_onboarding',
    });

    return new Response(JSON.stringify({ url: accountLink.url, accountId: stripeAccountId }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (err) {
    console.error('stripe-connect-onboard error:', err);
    return new Response(JSON.stringify({ error: err.message ?? 'Internal error' }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
  });