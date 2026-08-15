import { createClient } from 'npm:@supabase/supabase-js@2'

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

const STRIPE_API_BASE = 'https://api.stripe.com'

// Stripe deprecated the old beta-flag syntax (e.g. "2023-10-16;
// embedded_connect_beta=v2;") — the V2 namespace now just takes a plain
// dated version string. Current version per Stripe's versioning policy.
const STRIPE_API_VERSION = '2026-07-29.dahlia'

async function stripeV2Post(path: string, body: Record<string, unknown>, apiKey: string) {
  const res = await fetch(`${STRIPE_API_BASE}${path}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'Stripe-Version': STRIPE_API_VERSION,
    },
    body: JSON.stringify(body),
  })
  return res
}

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

    // ── Test/live key split ────────────────────────────────────────
    // STRIPE_SECRET_KEY (live) is the single source of truth for all real
    // businesses' Stripe operations and must never be overwritten again.
    // Sandbox/Connect testing now goes through a dedicated STRIPE_SECRET_KEY_TEST
    // secret instead, opted into explicitly per-request via test_mode, and only
    // for superusers — the same trust boundary already used for business_id
    // overrides. This replaces the old single-slot key that caused the 8/11
    // live-billing near-miss.
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
      .select('stripe_connect_id, owner_name, owner_email')
      .eq('id', business_id)
      .single()

    if (bizError) throw bizError

    const owner_name = business.owner_name ?? ''
    const owner_email = business.owner_email ?? ''

    if (!owner_name || !owner_email) {
      return new Response(
        JSON.stringify({ error: 'Owner name and email must be set in Business Profile before connecting Stripe.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Environment-aware redirect base ───────────────────────
    // Previously hardcoded to the production domain, so local dev testing
    // of the Connect onboarding redirect always landed on the live site
    // instead of localhost. Now derived from the calling browser's Origin
    // header, restricted to the production domain or a localhost dev port.
    const origin = req.headers.get('origin') ?? ''
    const isLocalDev = /^http:\/\/localhost:\d+$/.test(origin)
    const platformUrl = (origin === 'https://nexaflow-crm.web.app' || isLocalDev)
      ? origin
      : 'https://nexaflow-crm.web.app'

    let accountId = business.stripe_connect_id

    if (!accountId) {
      const accountRes = await stripeV2Post('/v2/core/accounts', {
        display_name: owner_name,
        contact_email: owner_email,
        dashboard: 'full',
        defaults: {
          responsibilities: {
            fees_collector: 'stripe',
            losses_collector: 'stripe',
          },
        },
        identity: {
          country: 'US',
          entity_type: 'company',
        },
        configuration: {
          merchant: {
            capabilities: {
              card_payments: { requested: true },
            },
          },
        },
      }, stripeApiKey)

      if (!accountRes.ok) {
        const err = await accountRes.json()
        throw new Error(err?.error?.message ?? 'Failed to create Stripe account')
      }

      const account = await accountRes.json()
      accountId = account.id

      const { error: updateError } = await supabase
        .from('businesses')
        .update({ stripe_connect_id: accountId })
        .eq('id', business_id)

      if (updateError) throw updateError
    }

    const linkRes = await stripeV2Post('/v2/core/account_links', {
      account: accountId,
      use_case: {
        type: 'account_onboarding',
        account_onboarding: {
          configurations: ['merchant'],
          refresh_url: `${platformUrl}/settings?stripe=refresh`,
          return_url: `${platformUrl}/settings?stripe=success`,
        },
      },
    }, stripeApiKey)

    if (!linkRes.ok) {
      const err = await linkRes.json()
      throw new Error(err?.error?.message ?? 'Failed to create account link')
    }

    const accountLink = await linkRes.json()

    return new Response(
      JSON.stringify({ url: accountLink.url, account_id: accountId }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('create-connect-account error:', err)
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})