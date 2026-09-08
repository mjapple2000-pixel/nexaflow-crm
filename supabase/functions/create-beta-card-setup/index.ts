import { createClient } from 'npm:@supabase/supabase-js@2'
import Stripe from 'npm:stripe@13'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2023-08-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const AI_OVERAGE_PRICE_ID = Deno.env.get('STRIPE_AI_OVERAGE_PRICE_ID') ?? ''

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Lets a beta business add a payment method so their AI usage can continue
// past the Pro-equivalent cap (2,500 msgs/mo) instead of pausing. Creates a
// Stripe Customer if one doesn't exist yet (beta accounts never go through
// real checkout, so client_id is normally null), then starts a Checkout
// Session in subscription mode with ONLY the metered AI-overage price
// attached — no flat fee. Once completed, stripe-webhook's existing
// checkout.session.completed handler (extended separately) saves the
// resulting subscription_id and flips beta_card_added to true, and
// report-ai-overage's existing metered-billing pipeline just works for
// this business from then on, unchanged.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    const callerToken = authHeader.replace('Bearer ', '')

    const { data: { user }, error: authError } = await supabase.auth.getUser(callerToken)
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { business_id } = await req.json()
    if (!business_id) {
      return new Response(
        JSON.stringify({ error: 'business_id is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Caller must own this business or be superuser
    const { data: suRow } = await supabase
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const isSuperuser = !!suRow

    if (!isSuperuser) {
      const { data: profile } = await supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .maybeSingle()

      if (!profile || profile.business_id !== business_id) {
        return new Response(
          JSON.stringify({ error: 'Forbidden' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }
    }

    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('id, business_name, owner_email, is_beta, client_id, beta_card_added')
      .eq('id', business_id)
      .single()

    if (bizError || !business) {
      return new Response(
        JSON.stringify({ error: 'Business not found.' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    if (!business.is_beta) {
      return new Response(
        JSON.stringify({ error: 'This is only available for beta accounts.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    if (!AI_OVERAGE_PRICE_ID) {
      console.error('STRIPE_AI_OVERAGE_PRICE_ID not set')
      return new Response(
        JSON.stringify({ error: 'Billing is not configured yet — contact support.' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Reuse an existing Stripe customer if this business already has one
    // (shouldn't normally happen for beta, but don't create a duplicate).
    let customerId = business.client_id
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: business.owner_email ?? undefined,
        name: business.business_name ?? undefined,
        metadata: { business_id: String(business.id), is_beta_account: 'true' },
      })
      customerId = customer.id
      await supabase.from('businesses').update({ client_id: customerId }).eq('id', business.id)
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      customer: customerId,
      line_items: [{ price: AI_OVERAGE_PRICE_ID }],
      metadata: {
        is_beta_card_setup: 'true',
        business_id: String(business.id),
      },
      success_url: `https://nexaflow-crm.web.app/settings?section=billing&beta_card=success`,
      cancel_url: `https://nexaflow-crm.web.app/settings?section=billing&beta_card=cancelled`,
    })

    return new Response(
      JSON.stringify({ url: session.url }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('create-beta-card-setup error:', err)
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})