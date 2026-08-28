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

    const { lead_ids, message, business_id, source } = await req.json()
    const targetSource = source === 'contacts' ? 'contacts' : 'leads'

    if (!lead_ids?.length || !message?.trim() || !business_id) {
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
    // check, meaning anyone with the URL could send SMS as any business to
    // any of that business's leads.
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

    const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
    const authToken  = Deno.env.get('TWILIO_AUTH_TOKEN')!
    const fromPhone  = '+18135500158'

    // Fetch targets — leads or business contacts, normalized to a common shape
    let targets: { id: number; name: string; phone: string | null }[] = []

    if (targetSource === 'contacts') {
      const { data, error } = await supabase
        .from('contacts')
        .select('id, full_name, phone')
        .in('id', lead_ids)
        .eq('business_id', business_id)
        .is('deleted_at', null)
      if (error) throw error
      targets = (data ?? []).map((c: any) => ({ id: c.id, name: c.full_name ?? 'Unknown', phone: c.phone }))
    } else {
      const { data, error } = await supabase
        .from('leads')
        .select('id, lead_name, lead_phone')
        .in('id', lead_ids)
        .eq('business_id', business_id)
      if (error) throw error
      targets = (data ?? []).map((l: any) => ({ id: l.id, name: l.lead_name ?? 'Unknown', phone: l.lead_phone }))
    }

    let sent = 0
    let skipped = 0
    const errors: string[] = []
    const linkColumn = targetSource === 'contacts' ? 'contact_id' : 'lead_id'

    for (const target of targets) {
      if (!target.phone) { skipped++; continue }

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
              To: target.phone,
              Body: message,
            }),
          }
        )

        if (!twilioRes.ok) {
          const err = await twilioRes.text()
          errors.push(`${target.name}: ${err}`)
          skipped++
          continue
        }

        // Find or create conversation — match by lead_id or contact_id, the
        // target's permanent identity. Phone numbers can change or be shared
        // and are not reliable.
        // Ordered + limited to 1 so this never breaks if duplicate rows exist —
        // it picks the most recently active one as canonical instead of
        // silently returning null (which would create yet another duplicate).
        const { data: convMatches } = await supabase
          .from('conversations')
          .select('id')
          .eq('business_id', business_id)
          .eq(linkColumn, target.id)
          .order('last_message_at', { ascending: false })
          .limit(1)
        let conv = convMatches?.[0] ?? null

        if (!conv) {
          const { data: newConv } = await supabase
            .from('conversations')
            .insert({
              [linkColumn]: target.id,
              business_id,
              contact_name: target.name,
              contact_phone: target.phone,
              channel: 'sms',
              status: 'open',
              last_message: message,
              last_message_at: new Date().toISOString(),
            })
            .select('id')
            .single()
          conv = newConv
        }

        if (conv) {
          // Insert message record — sent_via_twiml: true prevents the
          // outbound_messages webhook from re-sending via send-sms, since
          // this function already sent the SMS directly via Twilio above.
          await supabase.from('messages').insert({
            conversation_id: conv.id,
            business_id,
            direction: 'outbound',
            channel: 'sms',
            body: message,
            status: 'delivered',
            sender_name: 'You',
            sent_via_twiml: true,
          })

          // Update conversation — also backfill contact_name/contact_phone in case
          // this row was created by an older version of this function, or any
          // other path, without those fields set.
          await supabase
            .from('conversations')
            .update({
              last_message: message,
              last_message_at: new Date().toISOString(),
              contact_name: target.name,
              contact_phone: target.phone,
            })
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