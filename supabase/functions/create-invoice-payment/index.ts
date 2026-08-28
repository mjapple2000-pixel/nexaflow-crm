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
    // ── Auth: two legitimate callers only ──────────────────────────────
    // 1. client-portal-action, server-to-server, using the service role key —
    //    it has ALREADY verified the customer's private portal token owns
    //    this exact invoice before ever reaching here. Leads never call
    //    this function directly.
    // 2. A real staff member's own session, generating a link to send
    //    manually — must belong to the invoice's own business_id, checked
    //    below once the invoice is fetched.
    // Previously this endpoint accepted invoice_id with NO auth check at
    // all — a bare, unauthenticated request got back a live Stripe
    // Checkout URL plus the business name/job title/amount for any
    // invoice_id guessed.
    const authHeader = req.headers.get('Authorization') ?? ''
    const callerToken = authHeader.replace('Bearer ', '')
    const isInternalServiceCall = !!secretKeys.nexaflow_service_role_2026_08 && callerToken === secretKeys.nexaflow_service_role_2026_08

    let callerUserId: string | null = null
    if (!isInternalServiceCall) {
      const { data: { user }, error: authError } = await supabase.auth.getUser(callerToken)
      if (authError || !user) {
        return new Response(
          JSON.stringify({ error: 'Unauthorized' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }
      callerUserId = user.id
    }

    // JG-12: optional milestone_id. When present, this checkout session
    // is for ONE billing stage, not the whole invoice — amount, status
    // check, and session-id storage all resolve against the milestone
    // row instead of the invoice row. invoice_id is still required so we
    // can verify the milestone actually belongs to it (never trust a
    // bare milestone_id with no ownership check).
    const { invoice_id, milestone_id } = await req.json()

    if (!invoice_id) {
      return new Response(
        JSON.stringify({ error: 'invoice_id is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: invoice, error: invError } = await supabase
      .from('invoices')
      .select('id, business_id, contact_id, amount_due, job_title, status, is_progress_billed')
      .eq('id', invoice_id)
      .is('deleted_at', null)
      .single()

    if (invError || !invoice) {
      return new Response(
        JSON.stringify({ error: 'Invoice not found.' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Real staff callers must belong to this invoice's business (or be superuser)
    if (!isInternalServiceCall) {
      const { data: suRow } = await supabase
        .from('superusers')
        .select('user_id')
        .eq('user_id', callerUserId)
        .maybeSingle()
      const isSuperuser = !!suRow

      if (!isSuperuser) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', callerUserId)
          .maybeSingle()

        if (!profile || profile.business_id !== invoice.business_id) {
          return new Response(
            JSON.stringify({ error: 'Forbidden' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
          )
        }
      }
    }

    let payAmountDue = invoice.amount_due
    let payDescription = invoice.job_title?.trim() ? invoice.job_title : 'Invoice payment'
    let milestone: { id: number; label: string; status: string } | null = null

    if (milestone_id) {
      const { data: m, error: mErr } = await supabase
        .from('invoice_milestones')
        .select('id, invoice_id, label, status, amount_due')
        .eq('id', milestone_id)
        .eq('invoice_id', invoice_id)
        .is('deleted_at', null)
        .single()

      if (mErr || !m) {
        return new Response(
          JSON.stringify({ error: 'Milestone not found.' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }

      if (!['ready_to_bill', 'sent'].includes(m.status)) {
        return new Response(
          JSON.stringify({ error: 'This milestone is not payable in its current status.' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }

      milestone = { id: m.id, label: m.label, status: m.status }
      payAmountDue = m.amount_due
      payDescription = `${payDescription} — ${m.label}`
    } else {
      // Whole-invoice path — unchanged from before. Progress-billed
      // invoices should always be paid milestone-by-milestone, never as
      // one lump sum, so block that combination explicitly rather than
      // silently charging the full amount for a staged job.
      if (invoice.is_progress_billed) {
        return new Response(
          JSON.stringify({ error: 'This invoice is billed in stages — pay individual milestones instead.' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }
      if (!['approved', 'sent'].includes(invoice.status)) {
        return new Response(
          JSON.stringify({ error: 'This invoice is not payable in its current status.' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
        )
      }
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
    const amount_cents = Math.round(Number(payAmountDue) * 100)

    // Calculate platform fee
    const feePct = parseFloat(Deno.env.get('PLATFORM_FEE_PERCENT') ?? '1.0')
    const applicationFeeAmount = Math.round(amount_cents * (feePct / 100))

    const sessionParams = {
      payment_method_types: ['card'] as Stripe.Checkout.SessionCreateParams.PaymentMethodType[],
      mode: 'payment' as const,
      customer_email,
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: 'usd',
            unit_amount: amount_cents,
            product_data: {
              name: payDescription,
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

    // Track the session for later reconciliation — on the MILESTONE when
    // this is a staged payment, on the invoice otherwise. Keeping these
    // separate means stripe-connect-webhook can tell which kind of
    // payment just completed purely from which row the session id matches.
    if (milestone) {
      await supabase
        .from('invoice_milestones')
        .update({ stripe_checkout_session_id: session.id })
        .eq('id', milestone.id)
    } else {
      await supabase
        .from('invoices')
        .update({ stripe_checkout_session_id: session.id })
        .eq('id', invoice.id)
    }

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