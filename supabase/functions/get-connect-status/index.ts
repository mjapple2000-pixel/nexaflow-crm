import { createClient } from 'npm:@supabase/supabase-js@2'
import Stripe from 'npm:stripe@13'

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

// Stripe deprecated the old beta-flag syntax (e.g. "2023-10-16;
// embedded_connect_beta=v2;") — the V2 namespace now just takes a plain
// dated version string. Current version per Stripe's versioning policy.
const STRIPE_V2_API_VERSION = '2026-07-29.dahlia'

Deno.serve(async (req) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const { data: suRow } = await supabase
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const isSuperuser = !!suRow

    const body = await req.json().catch(() => ({}))

    // ── Test/live key split ── see create-connect-account for full rationale.
    // Sandbox Connect testing now uses a dedicated STRIPE_SECRET_KEY_TEST
    // secret, opted into per-request via test_mode, superuser-only.
    const useTestKey = isSuperuser && body?.test_mode === true
    const stripeApiKey = useTestKey
      ? (Deno.env.get('STRIPE_SECRET_KEY_TEST') ?? '')
      : (Deno.env.get('STRIPE_SECRET_KEY') ?? '')

    let business_id: number | null = null
    if (isSuperuser) {
      business_id = body?.business_id ?? null
      if (!business_id) {
        return new Response(JSON.stringify({ error: 'business_id is required' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
    } else {
      const { data: profile } = await supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .maybeSingle()
      if (!profile?.business_id) {
        return new Response(JSON.stringify({ error: 'No business found' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
      business_id = profile.business_id
    }

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

    const accountRes = await fetch(
      `https://api.stripe.com/v2/core/accounts/${business.stripe_connect_id}?include[0]=requirements&include[1]=configuration.merchant`,
      {
        headers: {
          'Authorization': `Bearer ${stripeApiKey}`,
          'Stripe-Version': STRIPE_V2_API_VERSION,
        },
      }
    )
    const account = await accountRes.json()

    const cardPaymentsStatus = account.configuration?.merchant?.capabilities?.card_payments?.status
    const payoutsStatus = account.configuration?.merchant?.capabilities?.stripe_balance?.payouts?.status
    const summaryStatus = account.requirements?.summary?.minimum_deadline?.status

    const onboarding_complete = summaryStatus == null || summaryStatus === 'eventually_due'
    const ready_to_charge = cardPaymentsStatus === 'active'

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