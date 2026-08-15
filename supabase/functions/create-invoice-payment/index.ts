import { createClient } from 'npm:@supabase/supabase-js@2'
import Stripe from 'npm:stripe@13'

const stripeLive = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2023-08-16',
  httpClient: Stripe.createFetchHttpClient(),
})
const stripeTest = new Stripe(Deno.env.get('STRIPE_SECRET_KEY_TEST') ?? '', {
  apiVersion: '2023-08-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
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
    // ── Accept only invoice_id ── never business_id/amount_cents/description ──
    // Previously this endpoint trusted business_id, amount_cents, and
    // description directly from the client with no auth check and no tie
    // to a real invoice at all — anyone could POST any business_id plus a
    // made-up amount and create a real Stripe Checkout Session against
    // that business's connected account, with the platform fee attached.
    // Callers here are external leads paying a bill, so there's no Supabase
    // session to check — the invoice_id itself, resolved server-side
    // against a real unpaid invoice, is what makes this safe.
    const { invoice_id } = await req.json()

    if (!invoice_id) {
      return new Response(
        JSON.stringify({ error: 'invoice_id is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: invoice, error: invError } = await supabase
      .from('invoices')
      .select('id, business_id, contact_id, amount_due, job_title, status')
      .eq('id', invoice_id)
      .is('deleted_at', null)
      .single()

    if (invError || !invoice) {
      return new Response(
        JSON.stringify({ error: 'Invoice not found.' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    if (!['approved', 'sent'].includes(invoice.status)) {
      return new Response(
        JSON.stringify({ error: 'This invoice is not payable in its current status.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Look up stripe_connect_id and verify ready
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('stripe_connect_id, stripe_connect_ready, business_name')
      .eq('id', invoice.business_id)
      .single()

    if (bizError) throw bizError

    if (!business.stripe_connect_id) {
      return new Response(
        JSON.stringify({ error: 'This business has not connected a Stripe account.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    if (!business.stripe_connect_ready) {
      return new Response(
        JSON.stringify({ error: 'Stripe account is not yet ready to accept payments.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Customer email comes from the invoice's own linked lead — never from the client
    let customer_email: string | undefined
    if (invoice.contact_id) {
      const { data: lead } = await supabase
        .from('leads')
        .select('lead_email')
        .eq('id', invoice.contact_id)
        .maybeSingle()
      customer_email = lead?.lead_email ?? undefined
    }

    // amount_due is stored in dollars (numeric) — Stripe wants integer cents
    const amount_cents = Math.round(Number(invoice.amount_due) * 100)
    const description = invoice.job_title?.trim() ? invoice.job_title : 'Invoice payment'

    // Calculate platform fee
    const feePct = parseFloat(Deno.env.get('PLATFORM_FEE_PERCENT') ?? '1.0')
    const applicationFeeAmount = Math.round(amount_cents * (feePct / 100))

    const sessionParams = {
      payment_method_types: ['card'],
      mode: 'payment' as const,
      customer_email,
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: 'usd',
            unit_amount: amount_cents,
            product_data: {
              name: description,
              description: `Payment to ${business.business_name ?? 'your service provider'}`,
            },
          },
        },
      ],
      payment_intent_data: {
        application_fee_amount: applicationFeeAmount,
      },
      success_url: `https://nexaflow-crm.web.app/payment-success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `https://nexaflow-crm.web.app/payment-cancelled`,
    }

    // Try the live key first (the normal case for every real business).
    // Some connected accounts in our system were created under a Stripe
    // TEST-mode key during earlier development/testing — Stripe rejects
    // those with a specific "created with a testmode key" error when called
    // with the live key. Rather than fail outright, detect exactly that
    // error and transparently retry once with the test key, so test-mode
    // connected accounts keep working without needing a special flag from
    // an unauthenticated caller (there's no Supabase session on this
    // endpoint — callers are external leads paying a bill).
    let session
    try {
      session = await stripeLive.checkout.sessions.create(sessionParams, {
        stripeAccount: business.stripe_connect_id,
      })
    } catch (err) {
      const message = (err as Error).message ?? ''
      const isTestModeAccountError = message.includes('was a test account created with a testmode key')
      if (!isTestModeAccountError) throw err
      console.log('Connected account is test-mode — retrying with test key:', business.stripe_connect_id)
      session = await stripeTest.checkout.sessions.create(sessionParams, {
        stripeAccount: business.stripe_connect_id,
      })
    }

    // Track the session on the invoice for later reconciliation
    await supabase
      .from('invoices')
      .update({ stripe_checkout_session_id: session.id })
      .eq('id', invoice.id)

    return new Response(
      JSON.stringify({ url: session.url, session_id: session.id }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('create-invoice-payment error:', err)
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})