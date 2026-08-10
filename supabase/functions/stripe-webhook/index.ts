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

// Maps Stripe Price IDs to internal plan names — never change these IDs
const PRICE_TO_PLAN: Record<string, string> = {
  'price_1TJJoyGpSG6sxQ0SW1kd9uoW': 'starter',
  'price_1TJJvYGpSG6sxQ0SlTuyLur8': 'growth',
  'price_1TJJy9GpSG6sxQ0SDBgCgpgH': 'pro',
}

// Maps Stripe subscription.status to our subscription_status values
const STRIPE_STATUS_MAP: Record<string, string> = {
  'active':             'active',
  'trialing':           'trialing',
  'past_due':           'past_due',
  'canceled':           'cancelled',   // Stripe spells it without the 'l'
  'unpaid':             'unpaid',
  'incomplete':         'incomplete',
  'incomplete_expired': 'cancelled',
}

// ── Single unified handler ───────────────────────────────────────────────
// Handles two destinations that share this URL:
//  - "Stripe Payment" (billing) → STRIPE_WEBHOOK_SECRET / STRIPE_WEBHOOK_SECRET_TEST
//  - "nexaflow-connect-v2" (V2 Connect, thin payload) → STRIPE_CONNECT_V2_WEBHOOK_SECRET
// This is a SEPARATE secret from STRIPE_CONNECT_WEBHOOK_SECRET, which belongs
// to the stripe-connect-webhook function / "nexaflow-connect-webhook" destination
// (leads paying businesses via their own connected accounts) — do not merge these.
//
// Uses constructEventAsync(): Deno's Edge Function runtime only exposes an
// async SubtleCrypto provider, so the synchronous constructEvent() always
// threw — every signature check was failing before secrets were ever compared.
Deno.serve(async (req: Request) => {
  // ── Manual cancel action from Flutter UI ──────────────────────────────
  // The Flutter cancel button calls this function directly with { action: 'cancel' }
  if (req.method === 'POST') {
    const contentType = req.headers.get('content-type') ?? ''
    if (contentType.includes('application/json')) {
      const cloned = req.clone()
      const body = await cloned.json().catch(() => null)
      if (body?.action === 'cancel' && body?.subscription_id) {
        try {
          await stripe.subscriptions.cancel(body.subscription_id)
          return new Response(JSON.stringify({ ok: true }), {
            headers: { 'Content-Type': 'application/json' },
          })
        } catch (err) {
          return new Response(JSON.stringify({ error: String(err) }), {
            status: 400,
            headers: { 'Content-Type': 'application/json' },
          })
        }
      }
    }
  }

  // ── Stripe webhook signature verification ─────────────────────────────
  // Try live billing secret, then test/sandbox billing secret, then the
  // V2 Connect secret (distinct from stripe-connect-webhook's secret).
  const signature = req.headers.get('stripe-signature')
  const rawBody = await req.text()

  let event: any = null
  let isConnectEvent = false

  const secretsToTry = [
    Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '',
    Deno.env.get('STRIPE_WEBHOOK_SECRET_TEST') ?? '',
  ]

  for (const secret of secretsToTry) {
    if (!secret) continue
    try {
      event = await stripe.webhooks.constructEventAsync(rawBody, signature ?? '', secret)
      break
    } catch (_e) {
      // try next secret
    }
  }

  if (!event) {
    try {
      event = await stripe.webhooks.constructEventAsync(
        rawBody,
        signature ?? '',
        Deno.env.get('STRIPE_CONNECT_V2_WEBHOOK_SECRET') ?? '',
      )
      isConnectEvent = true
    } catch (connectErr) {
      return new Response(`Webhook signature failed: ${connectErr}`, { status: 400 })
    }
  }

  // ── Billing events (NexaFlow subscriptions) ────────────────────────────
  if (!isConnectEvent) {
    // ── checkout.session.completed ────────────────────────────────────────
    // Sets is_paid, client_id, subscription_id only.
    // Plan name is set by customer.subscription.updated which fires immediately after.
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object as Stripe.Checkout.Session
      const customerEmail = session.customer_details?.email ?? ''
      const customerId = session.customer as string
      const subscriptionId = session.subscription as string

      const { data: business } = await supabase
        .from('businesses')
        .select('id, owner_name')
        .eq('owner_email', customerEmail)
        .maybeSingle()

      if (business) {
        await supabase
          .from('businesses')
          .update({
            is_paid: true,
            client_id: customerId,
            subscription_id: subscriptionId,
          })
          .eq('id', business.id)

        // Welcome email via Edge Function (Mailgun)
        await fetch('https://rllriopqojaraceytdno.supabase.co/functions/v1/welcome-email', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            to: customerEmail,
            owner_name: business.owner_name ?? 'there',
          }),
        })
      }
    }

    // ── customer.subscription.updated ────────────────────────────────────
    // Writes plan name and subscription lifecycle status separately.
    // This is the source of truth for both columns going forward.
    if (event.type === 'customer.subscription.updated') {
      const subscription = event.data.object as Stripe.Subscription
      const customerId = subscription.customer as string
      const priceId = subscription.items.data[0]?.price?.id ?? ''
      const planName = PRICE_TO_PLAN[priceId] ?? 'starter'
      const stripeStatus = subscription.status          // Stripe's lifecycle value
      const mappedStatus = STRIPE_STATUS_MAP[stripeStatus] ?? 'active'
      const isActive = ['active', 'trialing'].includes(mappedStatus)

      await supabase
        .from('businesses')
        .update({
          plan: planName,                  // e.g. 'growth'  — never 'cancelled'
          subscription_status: mappedStatus, // e.g. 'active', 'trialing', 'past_due'
          is_paid: isActive,
        })
        .eq('client_id', customerId)
    }

    // ── customer.subscription.deleted ────────────────────────────────────
    // Marks the subscription as cancelled and clears payment state.
    // Does NOT touch `plan` — we keep the last known plan for analytics/win-back.
    if (event.type === 'customer.subscription.deleted') {
      const subscription = event.data.object as Stripe.Subscription
      const customerId = subscription.customer as string

      await supabase
        .from('businesses')
        .update({
          is_paid: false,
          subscription_status: 'cancelled',
          subscription_id: null,
          // plan is intentionally NOT cleared here
        })
        .eq('client_id', customerId)
    }

    return new Response(JSON.stringify({ received: true }), {
      headers: { 'Content-Type': 'application/json' },
    })
  }

  // ── V2 Connect events (thin payload) ───────────────────────────────────
  // Handles account requirement and capability updates from connected accounts.

  // v2.core.account[requirements].updated — flip onboarded boolean
  if (event.type === 'v2.core.account[requirements].updated') {
    const accountId = event.related_object?.id ?? event.data?.object?.id
    if (accountId) {
      const account = await stripe.accounts.retrieve(accountId)
      const onboarded = account.details_submitted === true && account.charges_enabled === true
      await supabase
        .from('businesses')
        .update({ stripe_connect_onboarded: onboarded })
        .eq('stripe_connect_id', accountId)
    }
  }

  // v2.core.account[configuration.merchant].capability_status_updated — flip ready boolean
  if (event.type === 'v2.core.account[configuration.merchant].capability_status_updated') {
    const accountId = event.related_object?.id ?? event.data?.object?.id
    if (accountId) {
      const account = await stripe.accounts.retrieve(accountId)
      const ready =
        account.capabilities?.card_payments === 'active' && account.charges_enabled === true
      await supabase
        .from('businesses')
        .update({ stripe_connect_ready: ready })
        .eq('stripe_connect_id', accountId)
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' },
  })
})