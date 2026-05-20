import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const TWILIO_ACCOUNT_SID = Deno.env.get('TWILIO_ACCOUNT_SID')!
const TWILIO_AUTH_TOKEN = Deno.env.get('TWILIO_AUTH_TOKEN')!

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  console.log('Function called, method:', req.method)
  
  try {
    const rawBody = await req.text()
    console.log('Raw body:', rawBody)
    
    const payload = JSON.parse(rawBody)
    console.log('Parsed payload type:', payload.type)

    const record = payload.record ?? payload
    console.log('Record direction:', record?.direction)
    console.log('Record id:', record?.id)

    // Only process outbound messages
    if (record.direction !== 'outbound') {
      console.log('Skipping - not outbound')
      return new Response(JSON.stringify({ skipped: true }), { 
        status: 200, headers: corsHeaders 
      })
    }

    // Skip AI messages — already sent by receive-sms
    if (record.sent_via_twiml === true) {
      console.log('Skipping - already sent by receive-sms')
      return new Response(JSON.stringify({ skipped: true }), { 
        status: 200, headers: corsHeaders 
      })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: conversation, error: convError } = await supabase
      .from('conversations')
      .select('contact_phone, business_id')
      .eq('id', record.conversation_id)
      .single()

    console.log('Conversation:', conversation, 'Error:', convError)

    if (!conversation) {
      throw new Error(`Conversation not found: ${convError?.message}`)
    }

    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('ai_phone_number')
      .eq('id', conversation.business_id)
      .single()

    console.log('Business:', business, 'Error:', bizError)

    if (!business?.ai_phone_number) {
      throw new Error('No Twilio number assigned to this business')
    }

    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`
    
    const formData = new URLSearchParams()
    formData.append('To', conversation.contact_phone)
    formData.append('From', business.ai_phone_number)
    formData.append('Body', record.body)

    console.log('Sending SMS to:', conversation.contact_phone, 'from:', business.ai_phone_number)

    const twilioRes = await fetch(twilioUrl, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: formData.toString(),
    })

    const twilioData = await twilioRes.json()
    console.log('Twilio response:', JSON.stringify(twilioData))

    if (!twilioRes.ok) {
      throw new Error(`Twilio error: ${twilioData.message}`)
    }

    await supabase
      .from('messages')
      .update({ 
        status: 'delivered',
        twilio_sid: twilioData.sid 
      })
      .eq('id', record.id)

    console.log('Success! SID:', twilioData.sid)

    return new Response(JSON.stringify({ success: true, sid: twilioData.sid }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })

  } catch (error) {
    console.log('ERROR:', error.message)
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})