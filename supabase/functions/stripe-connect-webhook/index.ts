import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import Stripe from 'https://esm.sh/stripe@13.3.0?target=deno'

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient(),
})

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

serve(async (req) => {
  const signature = req.headers.get('stripe-signature')
  const body = await req.text()

  let event: Stripe.Event
  try {
    event = stripe.webhooks.constructEvent(
      body,
      signature ?? '',
      Deno.env.get('STRIPE_CONNECT_WEBHOOK_SECRET') ?? '',
    )
  } catch (err) {
    console.error('Webhook signature failed:', err)
    return new Response(`Webhook signature failed: ${err}`, { status: 400 })
  }

  // ── account.updated ────────────────────────────────────────────────
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

  // ── checkout.session.completed ─────────────────────────────────────
  // Fires on the connected account when a customer completes payment.
  // We match the invoice by amount and customer email within the business.
  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session

    // The connected account ID is in the event account field
    const connectedAccountId = (event as any).account as string | undefined
    const customerEmail = session.customer_details?.email ?? session.customer_email ?? ''
    const amountTotal = session.amount_total ?? 0

    if (connectedAccountId && customerEmail) {
      // Find the business by stripe_connect_id
      const { data: business } = await supabase
        .from('businesses')
        .select('id')
        .eq('stripe_connect_id', connectedAccountId)
        .maybeSingle()

      if (business) {
        // Find matching unpaid invoice by business + customer email + amount
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
              })
              .eq('id', invoice.id)

            // Also sync businesses table ready flag in case webhook fires
            await supabase
              .from('businesses')
              .update({ stripe_connect_ready: true })
              .eq('id', business.id)

            console.log(`checkout.session.completed: invoice ${invoice.id} marked paid for ${customerEmail}`)
          } else {
            console.log(`checkout.session.completed: no matching invoice for ${customerEmail} amount=${amountTotal}`)
          }
        }
      }
    }
  }

  // ── payment_intent.succeeded ───────────────────────────────────────
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
      const paidAt = new Date().toUTCString()

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