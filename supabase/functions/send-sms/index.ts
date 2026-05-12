import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const TWILIO_ACCOUNT_SID = Deno.env.get('TWILIO_ACCOUNT_SID')!
const TWILIO_AUTH_TOKEN = Deno.env.get('TWILIO_AUTH_TOKEN')!

serve(async (req) => {
  console.log('Function called, method:', req.method)
  
  try {
    const rawBody = await req.text()
    console.log('Raw body:', rawBody)
    
    const payload = JSON.parse(rawBody)
    console.log('Parsed payload type:', payload.type)

    // Supabase webhook sends {type, table, record, old_record}
    const record = payload.record ?? payload
    console.log('Record direction:', record?.direction)
    console.log('Record id:', record?.id)

    // Only process outbound messages
    if (record.direction !== 'outbound') {
      console.log('Skipping - not outbound')
      return new Response(JSON.stringify({ skipped: true }), { status: 200 })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Get conversation
    const { data: conversation, error: convError } = await supabase
      .from('conversations')
      .select('contact_phone, business_id')
      .eq('id', record.conversation_id)
      .single()

    console.log('Conversation:', conversation, 'Error:', convError)

    if (!conversation) {
      throw new Error(`Conversation not found: ${convError?.message}`)
    }

    // Get business Twilio number
    const { data: business, error: bizError } = await supabase
      .from('businesses')
      .select('ai_phone_number')
      .eq('id', conversation.business_id)
      .single()

    console.log('Business:', business, 'Error:', bizError)

    if (!business?.ai_phone_number) {
      throw new Error('No Twilio number assigned to this business')
    }

    // Send SMS via Twilio
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

    // Update message status
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
      headers: { 'Content-Type': 'application/json' },
    })

  } catch (error) {
    console.log('ERROR:', error.message)
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})