import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { lead_ids, subject, body, business_id, source } = await req.json()
    const targetSource = source === 'contacts' ? 'contacts' : 'leads'

    if (!lead_ids?.length || !subject?.trim() || !body?.trim() || !business_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const mailgunApiKey = Deno.env.get('MAILGUN_API_KEY')!
    const mailgunDomain = Deno.env.get('MAILGUN_DOMAIN')!
    const fromAddress   = `Vantagecaretech <vantagecaretech@gmail.com>`

    // Fetch targets — leads or business contacts, normalized to a common shape
    let targets: { id: number; name: string; email: string | null }[] = []

    if (targetSource === 'contacts') {
      const { data, error } = await supabase
        .from('contacts')
        .select('id, full_name, email')
        .in('id', lead_ids)
        .eq('business_id', business_id)
        .is('deleted_at', null)
      if (error) throw error
      targets = (data ?? []).map((c: any) => ({ id: c.id, name: c.full_name ?? 'Unknown', email: c.email }))
    } else {
      const { data, error } = await supabase
        .from('leads')
        .select('id, lead_name, lead_email')
        .in('id', lead_ids)
        .eq('business_id', business_id)
      if (error) throw error
      targets = (data ?? []).map((l: any) => ({ id: l.id, name: l.lead_name ?? 'Unknown', email: l.lead_email }))
    }

    let sent = 0
    let skipped = 0
    const errors: string[] = []
    const linkColumn = targetSource === 'contacts' ? 'contact_id' : 'lead_id'

    for (const target of targets) {
      if (!target.email) { skipped++; continue }

      try {
        // Personalize body — swap {{name}} if used
        const personalizedBody = body.replace(/\{\{name\}\}/gi, target.name)
        const personalizedSubject = subject.replace(/\{\{name\}\}/gi, target.name)

        // Send via Mailgun
        const formData = new FormData()
        formData.append('from', fromAddress)
        formData.append('to', `${target.name} <${target.email}>`)
        formData.append('subject', personalizedSubject)
        formData.append('text', personalizedBody)
        // Also send HTML version with line breaks preserved
        formData.append('html', `<div style="font-family:sans-serif;font-size:14px;line-height:1.6;color:#222">${personalizedBody.replace(/\n/g, '<br>')}</div>`)

        const mgRes = await fetch(
          `https://api.mailgun.net/v3/${mailgunDomain}/messages`,
          {
            method: 'POST',
            headers: {
              'Authorization': 'Basic ' + btoa(`api:${mailgunApiKey}`),
            },
            body: formData,
          }
        )

        if (!mgRes.ok) {
          const err = await mgRes.text()
          errors.push(`${target.name}: ${err}`)
          skipped++
          continue
        }

        // Find or create conversation
        let { data: conv } = await supabase
          .from('conversations')
          .select('id')
          .eq(linkColumn, target.id)
          .eq('business_id', business_id)
          .eq('channel', 'email')
          .maybeSingle()

        if (!conv) {
          const { data: newConv } = await supabase
            .from('conversations')
            .insert({
              [linkColumn]: target.id,
              business_id,
              contact_name: target.name,
              contact_email: target.email,
              channel: 'email',
              status: 'open',
              last_message_at: new Date().toISOString(),
            })
            .select('id')
            .single()
          conv = newConv
        }

        if (conv) {
          await supabase.from('messages').insert({
            conversation_id: conv.id,
            business_id,
            direction: 'outbound',
            channel: 'email',
            subject: personalizedSubject,
            body: personalizedBody,
            sent_at: new Date().toISOString(),
          })

          await supabase
            .from('conversations')
            .update({ last_message_at: new Date().toISOString() })
            .eq('id', conv.id)
        }

        // Update source record's last-contacted timestamp
        if (targetSource === 'contacts') {
          await supabase
            .from('contacts')
            .update({ last_contacted: new Date().toISOString() })
            .eq('id', target.id)
        } else {
          await supabase
            .from('leads')
            .update({ last_message_at: new Date().toISOString() })
            .eq('id', target.id)
        }

        sent++
      } catch (e) {
        errors.push(`${target.name}: ${e}`)
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