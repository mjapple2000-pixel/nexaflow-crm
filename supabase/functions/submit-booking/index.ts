import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { calendar_id, slot_start, slot_end, name, email, phone } = await req.json()

    // Validate required fields
    if (!calendar_id || !slot_start || !slot_end || !name || !email || !phone) {
      return new Response(
        JSON.stringify({ error: 'calendar_id, slot_start, slot_end, name, email, and phone are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Basic email validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ error: 'Invalid email address' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Basic phone validation — digits, spaces, dashes, parens, plus
    const phoneRegex = /^[\d\s\-\(\)\+]{7,20}$/
    if (!phoneRegex.test(phone)) {
      return new Response(
        JSON.stringify({ error: 'Invalid phone number' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Fetch the calendar — must be public and active
    // business_id is resolved server-side — never trusted from client
    const { data: calendar, error: calendarError } = await supabase
      .from('calendars')
      .select('id, business_id, name, duration_minutes, is_public, is_active')
      .eq('id', calendar_id)
      .eq('is_public', true)
      .eq('is_active', true)
      .single()

    if (calendarError || !calendar) {
      return new Response(
        JSON.stringify({ error: 'Calendar not found or not available for public booking' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const businessId = calendar.business_id

    // Race condition check — verify the slot is still available
    const { data: conflicting, error: conflictError } = await supabase
      .from('appointments')
      .select('id')
      .eq('calendar_id', calendar_id)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .neq('status', 'cancelled')
      .lt('start_date_time', slot_end)
      .gt('end_date_time', slot_start)
      .limit(1)

    if (conflictError) {
      console.error('Conflict check error:', conflictError)
      return new Response(
        JSON.stringify({ error: 'Failed to verify slot availability' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (conflicting && conflicting.length > 0) {
      return new Response(
        JSON.stringify({ error: 'This slot was just booked. Please select another time.' }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Upsert lead — if phone already exists for this business, update; otherwise insert
    const { data: existingLead } = await supabase
      .from('leads')
      .select('id')
      .eq('business_id', businessId)
      .eq('lead_phone', phone)
      .is('deleted_at', null)
      .maybeSingle()

    let leadId: number | null = null

    if (existingLead) {
      // Update existing lead
      const { data: updatedLead, error: updateError } = await supabase
        .from('leads')
        .update({
          lead_name: name,
          lead_email: email,
          lead_status: 'booked',
          converted_to_appointment: true,
          appointment_scheduled_at: slot_start,
          source: 'public_booking',
        })
        .eq('id', existingLead.id)
        .select('id')
        .single()

      if (updateError) {
        console.error('Lead update error:', updateError)
        return new Response(
          JSON.stringify({ error: 'Failed to update lead record' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
      leadId = updatedLead.id
    } else {
      // Insert new lead
      const { data: newLead, error: insertLeadError } = await supabase
        .from('leads')
        .insert({
          business_id: businessId,
          lead_name: name,
          lead_email: email,
          lead_phone: phone,
          lead_status: 'booked',
          converted_to_appointment: true,
          appointment_scheduled_at: slot_start,
          source: 'public_booking',
        })
        .select('id')
        .single()

      if (insertLeadError) {
        console.error('Lead insert error:', insertLeadError)
        return new Response(
          JSON.stringify({ error: 'Failed to create lead record' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
      leadId = newLead.id
    }

    // Insert the appointment
    const { data: appointment, error: apptError } = await supabase
      .from('appointments')
      .insert({
        business_id: businessId,
        calendar_id: calendar_id,
        appointment_name: `Booking - ${name}`,
        start_date_time: slot_start,
        end_date_time: slot_end,
        status: 'confirmed',
        appointment_type: 'appointment',
        lead_name: name,
        lead_email: email,
        lead_phone: phone,
        booking_source: 'public_booking',
        confirmation_sent: false,
      })
      .select('id')
      .single()

    if (apptError) {
      console.error('Appointment insert error:', apptError)
      return new Response(
        JSON.stringify({ error: 'Failed to create appointment' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // Send confirmation SMS via Twilio
    const twilioAccountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
    const twilioAuthToken = Deno.env.get('TWILIO_AUTH_TOKEN')!
    const twilioFromNumber = Deno.env.get('TWILIO_PHONE_NUMBER')!

    // Format the appointment time for the SMS
    const apptDate = new Date(slot_start)
    const formattedDate = apptDate.toLocaleDateString('en-US', {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      timeZone: 'America/New_York',
    })
    const formattedTime = apptDate.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      hour12: true,
      timeZone: 'America/New_York',
    })

    const smsBody = `Hi ${name}! Your appointment with ${calendar.name} is confirmed for ${formattedDate} at ${formattedTime}. We'll see you then!`

    // Normalize phone for Twilio — strip non-digits and ensure +1 prefix for US numbers
    const digitsOnly = phone.replace(/\D/g, '')
    const twilioToNumber = digitsOnly.startsWith('1') ? `+${digitsOnly}` : `+1${digitsOnly}`

    try {
      const twilioResponse = await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: new URLSearchParams({
            From: twilioFromNumber,
            To: twilioToNumber,
            Body: smsBody,
          }).toString(),
        }
      )

      if (twilioResponse.ok) {
        // Mark confirmation as sent
        await supabase
          .from('appointments')
          .update({ confirmation_sent: true })
          .eq('id', appointment.id)
      } else {
        const twilioError = await twilioResponse.text()
        console.error('Twilio error:', twilioError)
      }

      // Write to conversations + messages regardless of SMS outcome
      try {
          // Find existing conversation by lead_id, fall back to phone match
          const { data: existingConvo } = await supabase
            .from('conversations')
            .select('id')
            .eq('business_id', businessId)
            .eq('lead_id', leadId)
            .maybeSingle()

          let conversationId: number | null = null

          if (existingConvo) {
            conversationId = existingConvo.id
            await supabase
              .from('conversations')
              .update({ last_message: smsBody, last_message_at: new Date().toISOString() })
              .eq('id', conversationId)
          } else {
            const { data: newConvo, error: convoError } = await supabase
              .from('conversations')
              .insert({
                business_id: businessId,
                lead_id: leadId,
                contact_name: name,
                contact_phone: twilioToNumber,
                contact_email: email,
                last_message: smsBody,
                last_message_at: new Date().toISOString(),
                channel: 'sms',
                status: 'open',
              })
              .select('id')
              .single()

            if (convoError) {
              console.error('Conversation insert error:', convoError)
            } else {
              conversationId = newConvo.id
            }
          }

          if (conversationId) {
            await supabase.from('messages').insert({
              business_id: businessId,
              conversation_id: conversationId,
              body: smsBody,
              direction: 'outbound',
              channel: 'sms',
              status: 'sent',
              sent_via_twiml: false,
            })
          }
        } catch (convoErr) {
        console.error('Conversation write error:', convoErr)
        // Don't fail the booking if conversation write fails
      }
    } catch (smsErr) {
      console.error('SMS send error:', smsErr)
      // Don't fail the booking if SMS fails
    }

    // Return success
    return new Response(
      JSON.stringify({
        success: true,
        appointment_id: appointment.id,
        message: `Appointment confirmed for ${formattedDate} at ${formattedTime}`,
        calendar_name: calendar.name,
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (err) {
    console.error('Unexpected error:', err)
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})