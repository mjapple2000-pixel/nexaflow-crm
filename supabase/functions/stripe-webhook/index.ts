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

const PRICE_TO_PLAN: Record<string, string> = {
  'price_1TJJoyGpSG6sxQ0SW1kd9uoW': 'starter',
  'price_1TJJvYGpSG6sxQ0SlTuyLur8': 'growth',
  'price_1TJJy9GpSG6sxQ0SDBgCgpgH': 'pro',
}

serve(async (req) => {
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

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session

    // Get the price ID from the line items
    const lineItems = await stripe.checkout.sessions.listLineItems(session.id)
    const priceId = lineItems.data[0]?.price?.id ?? ''
    const planName = PRICE_TO_PLAN[priceId] ?? 'starter'

    const customerEmail = session.customer_details?.email ?? ''
    const customerId = session.customer as string
    const subscriptionId = session.subscription as string

    // Find the business by owner email
    const { data: business } = await supabase
      .from('businesses')
      .select('id')
      .eq('owner_email', customerEmail)
      .maybeSingle()

    if (business) {
      await supabase
        .from('businesses')
        .update({
          is_paid: true,
          subscription_status: planName,
          client_id: customerId,
          subscription_id: subscriptionId,
        })
        .eq('id', business.id)
    }
  }

  if (event.type === 'customer.subscription.deleted') {
    const subscription = event.data.object as Stripe.Subscription
    const customerId = subscription.customer as string

    await supabase
      .from('businesses')
      .update({
        is_paid: false,
        subscription_status: 'cancelled',
        subscription_id: null,
      })
      .eq('client_id', customerId)
  }

  if (event.type === 'customer.subscription.updated') {
    const subscription = event.data.object as Stripe.Subscription
    const customerId = subscription.customer as string
    const priceId = subscription.items.data[0]?.price?.id ?? ''
    const planName = PRICE_TO_PLAN[priceId] ?? 'starter'
    const isActive = subscription.status === 'active'

    await supabase
      .from('businesses')
      .update({
        is_paid: isActive,
        subscription_status: isActive ? planName : 'cancelled',
      })
      .eq('client_id', customerId)
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' },
  })
})