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

serve(async (req) => {
  // ── Manual cancel action from Flutter UI ──────────────────────────────
  // The Flutter cancel button calls this function directly with { action: 'cancel' }
  if (req.method === 'POST') {
    const contentType = req.headers.get('content-type') ?? ''
    if (contentType.includes('application/json')) {
      const body = await req.json().catch(() => null)
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
  const signature = req.headers.get('stripe-signature')
  const body = await req.text()

  let event: Stripe.Event
  try {
    event = stripe.webhooks.constructEvent(
      body,
      signature ?? '',
      Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '',
    )
  } catch (err) {
    return new Response(`Webhook signature failed: ${err}`, { status: 400 })
  }

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

      // Welcome email via Make
      await fetch('https://hook.us2.make.com/217vu6f50oluiu9e01thnx4dutehbdne', {
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
})

// ── V2 Connect thin event handler (separate export) ───────────────────────
// Handles account requirement and capability updates from connected accounts.
// Uses a separate webhook secret from NexaFlow's own billing webhook above.
Deno.serve(async (req: Request) => {
  const signature = req.headers.get('stripe-signature')
  const body = await req.text()

  let event: any
  try {
    event = stripe.webhooks.constructEvent(
      body,
      signature ?? '',
      Deno.env.get('STRIPE_CONNECT_WEBHOOK_SECRET') ?? '',
    )
  } catch (err) {
    return new Response(`Connect webhook signature failed: ${err}`, { status: 400 })
  }

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