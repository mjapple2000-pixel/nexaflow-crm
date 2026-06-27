import { createClient } from 'npm:@supabase/supabase-js@2'
import Stripe from 'npm:stripe@13'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2023-08-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

Deno.serve(async (req) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { business_id } = await req.json()

    if (!business_id) {
      return new Response(
        JSON.stringify({ error: 'business_id is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Look up stripe_connect_id
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('stripe_connect_id, stripe_connect_onboarded, stripe_connect_ready')
      .eq('id', business_id)
      .single()

    if (bizError) throw bizError

    if (!business.stripe_connect_id) {
      return new Response(
        JSON.stringify({ onboarding_complete: false, ready_to_charge: false }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Retrieve live V2 account with capability details
    const accountRes = await fetch(
      `https://api.stripe.com/v2/core/accounts/${business.stripe_connect_id}?include[]=requirements&include[]=configuration.merchant`,
      {
        headers: {
          'Authorization': `Bearer ${Deno.env.get('STRIPE_SECRET_KEY') ?? ''}`,
          'Stripe-Version': '2023-10-16; embedded_connect_beta=v2;',
        },
      }
    )
    const account = await accountRes.json()

    const cardPaymentsStatus = account.configuration?.merchant?.capabilities?.card_payments?.status
    const payoutsStatus = account.configuration?.merchant?.capabilities?.stripe_balance?.payouts?.status
    const summaryStatus = account.requirements?.summary?.minimum_deadline?.status

    const onboarding_complete = summaryStatus == null || summaryStatus === 'eventually_due'
    const ready_to_charge = cardPaymentsStatus === 'active'

    // Sync booleans back to businesses table if changed
    if (
      onboarding_complete !== business.stripe_connect_onboarded ||
      ready_to_charge !== business.stripe_connect_ready
    ) {
      await supabase
        .from('businesses')
        .update({
          stripe_connect_onboarded: onboarding_complete,
          stripe_connect_ready: ready_to_charge,
        })
        .eq('id', business_id)
    }

    return new Response(
      JSON.stringify({ onboarding_complete, ready_to_charge }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('get-connect-status error:', err)
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})