import { createClient } from 'npm:@supabase/supabase-js@2'
import Stripe from 'npm:stripe@13.3.0'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

// Uses constructEventAsync(): Deno's Edge Function runtime only exposes an
// async SubtleCrypto provider, so the synchronous constructEvent() always
// threw — every signature check was failing before the secret was ever
// compared. Same class of bug found and fixed in stripe-webhook today.
// This function's secret (STRIPE_CONNECT_WEBHOOK_SECRET) belongs to the
// "nexaflow-connect-webhook" destination — leads paying businesses via
// their own connected Stripe accounts. Do NOT confuse with
// STRIPE_CONNECT_V2_WEBHOOK_SECRET, which belongs to stripe-webhook's
// separate "nexaflow-connect-v2" destination.
Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature')
  const body = await req.text()

  let event: Stripe.Event
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature ?? '',
      Deno.env.get('STRIPE_CONNECT_WEBHOOK_SECRET') ?? '',
    )
  } catch (err) {
    console.error('Webhook signature failed:', err)
    return new Response(`Webhook signature failed: ${err}`, { status: 400 })
  }

  console.log('stripe-connect-webhook received event:', event.type)

  // ── account.updated ──
  if (event.type === 'account.updated') {
    const account = event.data.object as Stripe.Account

    const chargesEnabled = account.charges_enabled ?? false
    const payoutsEnabled = account.payouts_enabled ?? false
    const onboardingComplete = chargesEnabled && payoutsEnabled

    const { error } = await supabase
      .from('stripe_connect_accounts')
      .update({
        onboarding_complete: onboardingComplete,
        charges_enabled: chargesEnabled,
        payouts_enabled: payoutsEnabled,
      })
      .eq('stripe_account_id', account.id)
      .is('deleted_at', null)

    if (error) {
      console.error('Failed to update stripe_connect_accounts:', error)
      return new Response(JSON.stringify({ error: error.message }), { status: 500 })
    }

    console.log(`account.updated: ${account.id} charges=${chargesEnabled} payouts=${payoutsEnabled}`)
  }

  // ── checkout.session.completed ──
  // Fires on the connected account when a customer completes payment.
  // create-invoice-payment always writes stripe_checkout_session_id onto
  // the invoice at session-creation time — matching on that exact id is
  // reliable and can't fail. The old amount+email heuristic below is kept
  // ONLY as a fallback for any invoice that somehow has no session id
  // recorded (e.g. an older/other flow), since Stripe test checkouts often
  // don't collect a customer email at all, which made that heuristic
  // silently match nothing — the invoice just never flipped to paid, with
  // no error anywhere.
  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session
    const amountTotal = session.amount_total ?? 0

    // Primary path: exact match on the session id we stored ourselves.
    const { data: invoiceBySession } = await supabase
      .from('invoices')
      .select('id, business_id')
      .eq('stripe_checkout_session_id', session.id)
      .in('status', ['approved', 'sent'])
      .is('deleted_at', null)
      .maybeSingle()

    if (invoiceBySession) {
      const now = new Date().toISOString()
      await supabase
        .from('invoices')
        .update({
          status: 'paid',
          paid_at: now,
          updated_at: now,
          amount_paid: amountTotal / 100,
        })
        .eq('id', invoiceBySession.id)

      await supabase
        .from('businesses')
        .update({ stripe_connect_ready: true })
        .eq('id', invoiceBySession.business_id)

      console.log(`checkout.session.completed: invoice ${invoiceBySession.id} marked paid via session id match (${session.id})`)
    } else {
      // Fallback: old amount+email heuristic
      const connectedAccountId = (event as any).account as string | undefined
      const customerEmail = session.customer_details?.email ?? session.customer_email ?? ''

      if (connectedAccountId && customerEmail) {
        const { data: business } = await supabase
          .from('businesses')
          .select('id')
          .eq('stripe_connect_id', connectedAccountId)
          .maybeSingle()

        if (business) {
          const { data: lead } = await supabase
            .from('leads')
            .select('id')
            .eq('business_id', business.id)
            .eq('lead_email', customerEmail)
            .maybeSingle()

          if (lead) {
            const { data: invoice } = await supabase
              .from('invoices')
              .select('id')
              .eq('business_id', business.id)
              .eq('contact_id', lead.id)
              .eq('amount_due', amountTotal / 100)
              .in('status', ['approved', 'sent'])
              .filter('deleted_at', 'is', null)
              .order('created_at', { ascending: false })
              .limit(1)
              .maybeSingle()

            if (invoice) {
              const now = new Date().toISOString()
              await supabase
                .from('invoices')
                .update({
                  status: 'paid',
                  paid_at: now,
                  updated_at: now,
                  amount_paid: amountTotal / 100,
                })
                .eq('id', invoice.id)

              await supabase
                .from('businesses')
                .update({ stripe_connect_ready: true })
                .eq('id', business.id)

              console.log(`checkout.session.completed: invoice ${invoice.id} marked paid via amount+email fallback for ${customerEmail}`)
            } else {
              console.log(`checkout.session.completed: no matching invoice (fallback) for ${customerEmail} amount=${amountTotal}`)
            }
          }
        }
      } else {
        console.log(`checkout.session.completed: no session-id match and no email/account to fall back on (session ${session.id})`)
      }
    }
  }

  // ── payment_intent.succeeded ──
  if (event.type === 'payment_intent.succeeded') {
    const intent = event.data.object as Stripe.PaymentIntent

    // Look up the payment link by stripe_payment_intent_id
    const { data: paymentLink, error: plErr } = await supabase
      .from('payment_links')
      .select('id, invoice_id')
      .eq('stripe_payment_intent_id', intent.id)
      .is('deleted_at', null)
      .maybeSingle()

    if (plErr) {
      console.error('Failed to look up payment_link:', plErr)
      return new Response(JSON.stringify({ error: plErr.message }), { status: 500 })
    }

    if (paymentLink) {
      const amountReceived = intent.amount_received ?? intent.amount ?? 0

      // Mark payment link as paid
      await supabase
        .from('payment_links')
        .update({ status: 'paid', paid_at: new Date().toISOString() })
        .eq('id', paymentLink.id)

      // Update invoice: status → paid, paid_at stamped
      await supabase
        .from('invoices')
        .update({
          status: 'paid',
          paid_at: new Date().toISOString(),
          amount_paid: amountReceived / 100,
        })
        .eq('id', paymentLink.invoice_id)

      console.log(`payment_intent.succeeded: ${intent.id} → invoice ${paymentLink.invoice_id} marked paid`)
    } else {
      // Not a NexaFlow-managed payment intent — ignore silently
      console.log(`payment_intent.succeeded: ${intent.id} — no matching payment_link, skipping`)
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' },
  })
})
