import { createClient } from 'npm:@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? ''
const STRIPE_API_BASE = 'https://api.stripe.com'

async function stripeV2Post(path: string, body: Record<string, unknown>) {
  const res = await fetch(`${STRIPE_API_BASE}${path}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/json',
      'Stripe-Version': '2023-10-16; embedded_connect_beta=v2;',
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
    const { business_id, owner_name, owner_email } = await req.json()

    if (!business_id || !owner_name || !owner_email) {
      return new Response(
        JSON.stringify({ error: 'business_id, owner_name, and owner_email are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Check if already connected
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('stripe_connect_id')
      .eq('id', business_id)
      .single()

    if (bizError) throw bizError

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