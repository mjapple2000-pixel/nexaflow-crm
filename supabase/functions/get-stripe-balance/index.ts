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
    // ── Resolve business_id server-side from the caller's own session ─────
    // Superuser bypass: platform admins (rows in public.superusers) may
    // pass business_id in the body to troubleshoot another business's
    // Stripe balance. Everyone else gets their own business_id from their
    // profile — client-supplied business_id is ignored for them.
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

    // Same lookup as get-connect-status — stripe_connect_id is the real
    // V2 account identifier (NOT businesses.stripe_connect_account_id,
    // which is an orphaned column no current function writes to).
    // stripe_connect_ready reflects whether the account can actually
    // charge/hold a balance yet.
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('stripe_connect_id, stripe_connect_ready')
      .eq('id', business_id)
      .single()

    if (bizError) throw bizError

    if (!business.stripe_connect_id || !business.stripe_connect_ready) {
      // Not connected/ready yet — expected state, not an error. The Jobs
      // Overview page shows a "Connect Stripe" teaser for this response.
      return new Response(
        JSON.stringify({ connected: false }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Balance is a plain concept that still applies to a connected account
    // regardless of whether it was created via the V1 or V2 Accounts API —
    // retrieved via the SDK using stripeAccount, same as any other
    // per-connected-account call.
    const balance = await stripe.balance.retrieve({
      stripeAccount: business.stripe_connect_id,
    })

    const available_cents = (balance.available ?? []).reduce((sum, b) => sum + b.amount, 0)
    const pending_cents = (balance.pending ?? []).reduce((sum, b) => sum + b.amount, 0)

    return new Response(
      JSON.stringify({ connected: true, available_cents, pending_cents }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('get-stripe-balance error:', err)
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})