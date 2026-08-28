import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { lead_ids, subject, body, business_id, source } = await req.json()
    const targetSource = source === 'contacts' ? 'contacts' : 'leads'

    if (!lead_ids?.length || !subject?.trim() || !body?.trim() || !business_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      secretKeys.nexaflow_service_role_2026_08 ?? ''
    )

    // ── Verify caller is a real logged-in user who actually belongs to
    // business_id (or is a verified superuser) — previously this function
    // trusted business_id straight from the request body with zero auth
    // check, meaning anyone with the URL could send email as any business
    // to any of that business's leads.
    const { data: { user }, error: userErr } = await supabase.auth.getUser(authHeader.replace('Bearer ', ''))
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: 'Invalid or expired session' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { data: suRow } = await supabase
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const isSuperuser = !!suRow

    if (!isSuperuser) {
      const { data: profile } = await supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .maybeSingle()

      if (!profile || profile.business_id !== business_id) {
        return new Response(JSON.stringify({ error: 'Forbidden' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
      }
    }

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
        // HTML version — escape BEFORE converting newlines to <br>, so
        // neither the staff-typed body nor an injected target.name (which
        // could come from a CSV import with no content restriction) can
        // inject raw HTML/script into the outbound email.
        const escapedHtmlBody = personalizedBody
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;')
          .replace(/'/g, '&#39;')
        formData.append('html', `<div style="font-family:sans-serif;font-size:14px;line-height:1.6;color:#222">${escapedHtmlBody.replace(/\n/g, '<br>')}</div>`)

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