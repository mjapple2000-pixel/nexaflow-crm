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

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { invoice_id, business_id, channel } = await req.json()

    if (!invoice_id || !business_id || !channel) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    // 1. Load Connect account — must have charges_enabled
    const { data: connectAccount, error: caErr } = await supabase
      .from('stripe_connect_accounts')
      .select('stripe_account_id, charges_enabled')
      .eq('business_id', business_id)
      .is('deleted_at', null)
      .maybeSingle()

    if (caErr) throw new Error(caErr.message)
    if (!connectAccount) throw new Error('No Stripe Connect account found for this business.')
    if (!connectAccount.charges_enabled) throw new Error('Stripe Connect account is not yet enabled for charges. Complete onboarding first.')

    // 2. Load invoice + lead
    const { data: invoice, error: invErr } = await supabase
      .from('invoices')
      .select('*, leads(id, lead_name, lead_email, lead_phone)')
      .eq('id', invoice_id)
      .eq('business_id', business_id)
      .single()

    if (invErr) throw new Error(invErr.message)
    if (!invoice) throw new Error('Invoice not found.')

    const lead = invoice.leads as Record<string, unknown>
    const amountDue = Math.round((invoice.amount_due as number) * 100) // cents

    if (amountDue <= 0) throw new Error('Invoice amount must be greater than zero.')

    const platformFeePercent = parseFloat(Deno.env.get('STRIPE_PLATFORM_FEE_PERCENT') ?? '0')
    const applicationFeeAmount = Math.round(amountDue * (platformFeePercent / 100))

    // 3. Create Stripe PaymentIntent on connected account
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amountDue,
      currency: 'usd',
      payment_method_types: ['card'],
      description: `Invoice ${invoice.invoice_number} — ${lead.lead_name}`,
      ...(applicationFeeAmount > 0 && {
        application_fee_amount: applicationFeeAmount,
      }),
    }, {
      stripeAccount: connectAccount.stripe_account_id,
    })

    // 4. Build payment URL (Stripe-hosted payment page via client secret)
    // We store the intent ID; the actual payment page URL is constructed from the client secret
    const paymentUrl = `https://checkout.stripe.com/c/pay/${paymentIntent.client_secret}`

    // 5. Write to payment_links
    const { data: paymentLink, error: plErr } = await supabase
      .from('payment_links')
      .insert({
        business_id,
        invoice_id,
        stripe_payment_intent_id: paymentIntent.id,
        stripe_payment_link_url: paymentUrl,
        amount_cents: amountDue,
        currency: 'usd',
        status: 'pending',
      })
      .select('id')
      .single()

    if (plErr) throw new Error(plErr.message)

    // 6. Update invoice with payment_link_id
    await supabase
      .from('invoices')
      .update({ payment_link_id: paymentLink.id })
      .eq('id', invoice_id)

    // 7. Send notification via chosen channel
    const leadId   = lead.id as number
    const leadName = lead.lead_name as string ?? 'there'
    const leadPhone = lead.lead_phone as string ?? ''
    const invoiceNum = invoice.invoice_number as string ?? 'Invoice'
    const amountFmt = `$${(amountDue / 100).toFixed(2)}`
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''

    if (channel === 'sms') {
      if (!leadPhone) throw new Error('Lead has no phone number on file.')

      const twilioSid   = Deno.env.get('TWILIO_ACCOUNT_SID')!
      const twilioToken = Deno.env.get('TWILIO_AUTH_TOKEN')!
      const fromNumber  = Deno.env.get('TWILIO_PHONE_NUMBER') ?? '+18135500158'

      const smsBody = `Hi ${leadName}, your invoice ${invoiceNum} for ${amountFmt} is ready. Pay securely here: ${paymentUrl}`

      const formData = new URLSearchParams()
      formData.append('To', leadPhone)
      formData.append('From', fromNumber)
      formData.append('Body', smsBody)

      const twilioRes = await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${twilioSid}/Messages.json`,
        {
          method: 'POST',
          headers: {
            'Authorization': 'Basic ' + btoa(`${twilioSid}:${twilioToken}`),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: formData.toString(),
        }
      )

      if (!twilioRes.ok) {
        const err = await twilioRes.text()
        throw new Error(`Twilio error: ${err}`)
      }

    } else if (channel === 'email') {
      const leadEmail = lead.lead_email as string ?? ''
      if (!leadEmail) throw new Error('Lead has no email address on file.')

      const emailBody =
        `Hi ${leadName},\n\n` +
        `Your invoice ${invoiceNum} for ${amountFmt} is ready for payment.\n\n` +
        `Pay securely here:\n${paymentUrl}\n\n` +
        `Thank you for your business!`

      await fetch(`${supabaseUrl}/functions/v1/send-email`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          lead_ids: [leadId],
          subject: `Invoice ${invoiceNum} — Payment Due ${amountFmt}`,
          body: emailBody,
          business_id,
        }),
      })
    }

    return new Response(
      JSON.stringify({ success: true, payment_link_id: paymentLink.id, payment_url: paymentUrl }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (e) {
    console.error('generate-payment-link error:', e)
    return new Response(JSON.stringify({ error: String(e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})