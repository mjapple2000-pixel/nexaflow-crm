import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { lead_ids, message, business_id } = await req.json()

    if (!lead_ids?.length || !message?.trim() || !business_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
    const authToken  = Deno.env.get('TWILIO_AUTH_TOKEN')!
    const fromPhone  = '+18135500158'

    // Fetch leads
    const { data: leads, error: leadsError } = await supabase
      .from('leads')
      .select('id, lead_name, lead_phone')
      .in('id', lead_ids)
      .eq('business_id', business_id)

    if (leadsError) throw leadsError

    let sent = 0
    let skipped = 0
    const errors: string[] = []

    for (const lead of leads ?? []) {
      if (!lead.lead_phone) { skipped++; continue }

      try {
        // Send via Twilio
        const twilioRes = await fetch(
          `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
          {
            method: 'POST',
            headers: {
              'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
              From: fromPhone,
              To: lead.lead_phone,
              Body: message,
            }),
          }
        )

        if (!twilioRes.ok) {
          const err = await twilioRes.text()
          errors.push(`${lead.lead_name}: ${err}`)
          skipped++
          continue
        }

        // Find or create conversation
        let { data: conv } = await supabase
          .from('conversations')
          .select('id')
          .eq('lead_id', lead.id)
          .eq('business_id', business_id)
          .maybeSingle()

        if (!conv) {
          const { data: newConv } = await supabase
            .from('conversations')
            .insert({
              lead_id: lead.id,
              business_id,
              channel: 'sms',
              status: 'open',
              last_message_at: new Date().toISOString(),
            })
            .select('id')
            .single()
          conv = newConv
        }

        if (conv) {
          // Insert message record
          await supabase.from('messages').insert({
            conversation_id: conv.id,
            business_id,
            direction: 'outbound',
            channel: 'sms',
            body: message,
            sent_at: new Date().toISOString(),
          })

          // Update conversation last_message_at
          await supabase
            .from('conversations')
            .update({ last_message_at: new Date().toISOString() })
            .eq('id', conv.id)
        }

        // Update lead last_message_at
        await supabase
          .from('leads')
          .update({ last_message_at: new Date().toISOString() })
          .eq('id', lead.id)

        sent++
      } catch (e) {
        errors.push(`${lead.lead_name}: ${e}`)
        skipped++
      }
    }

    return new Response(
      JSON.stringify({ sent, skipped, errors }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
  }
})