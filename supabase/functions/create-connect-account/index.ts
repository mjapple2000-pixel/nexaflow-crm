import { createClient } from 'npm:@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? ''
const STRIPE_API_BASE = 'https://api.stripe.com'

// Stripe deprecated the old beta-flag syntax (e.g. "2023-10-16;
// embedded_connect_beta=v2;") — the V2 namespace now just takes a plain
// dated version string. Current version per Stripe's versioning policy.
const STRIPE_API_VERSION = '2026-07-29.dahlia'

async function stripeV2Post(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${STRIPE_API_BASE}${path}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${STRIPE_SECRET_KEY}`,
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
    // ── Resolve business_id server-side from the caller's own session ─────
    // Previously this endpoint had NO auth check at all, and trusted
    // business_id, owner_name, and owner_email straight from the client —
    // anyone could create a real Stripe Connect account and attach it to
    // any business_id. Superuser bypass: platform admins (rows in
    // public.superusers) may pass business_id in the body to set up
    // Connect on another business's behalf. Everyone else gets their own
    // business_id from their profile. owner_name/owner_email are now
    // always read from the business record itself, never from the client.
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

    // Check if already connected — also pull owner_name/owner_email from
    // the business record itself, never trust these from the client.
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

    let accountId = business.stripe_connect_id

    // Create V2 account if not already created
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
      })

      if (!accountRes.ok) {
        const err = await accountRes.json()
        throw new Error(err?.error?.message ?? 'Failed to create Stripe account')
      }

      const account = await accountRes.json()
      accountId = account.id

      // Store on businesses table
      const { error: updateError } = await supabase
        .from('businesses')
        .update({ stripe_connect_id: accountId })
        .eq('id', business_id)

      if (updateError) throw updateError
    }

    // Create V2 Account Link for onboarding
    const linkRes = await stripeV2Post('/v2/core/account_links', {
      account: accountId,
      use_case: {
        type: 'account_onboarding',
        account_onboarding: {
          configurations: ['merchant'],
          refresh_url: 'https://nexaflow-crm.web.app/settings?stripe=refresh',
          return_url: `https://nexaflow-crm.web.app/settings?stripe=success`,
        },
      },
    })

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