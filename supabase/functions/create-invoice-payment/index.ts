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
    const { business_id, amount_cents, description, customer_email } = await req.json()

    if (!business_id || !amount_cents || !description || !customer_email) {
      return new Response(
        JSON.stringify({ error: 'business_id, amount_cents, description, and customer_email are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // Look up stripe_connect_id and verify ready
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('stripe_connect_id, stripe_connect_ready, business_name')
      .eq('id', business_id)
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

    // Calculate platform fee
    const feePct = parseFloat(Deno.env.get('PLATFORM_FEE_PERCENT') ?? '1.0')
    const applicationFeeAmount = Math.round(amount_cents * (feePct / 100))

    // Create Checkout Session using Direct Charge on connected account
    const session = await stripe.checkout.sessions.create(
      {
        payment_method_types: ['card'],
        mode: 'payment',
        customer_email: customer_email,
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
      },
      {
        stripeAccount: business.stripe_connect_id,
      },
    )

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