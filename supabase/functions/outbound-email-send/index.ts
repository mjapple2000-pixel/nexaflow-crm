const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { to, subject, body, conversation_id } = await req.json()

    if (!to || !body) {
      return new Response(
        JSON.stringify({ error: 'to and body are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!MAILGUN_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'Mailgun is not configured' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // ── Resolve the sending business's own reply-to email, server-side ──────
    // Never trust business context from the client — always derive it from
    // conversation_id -> conversations.business_id -> businesses.owner_email.
    let replyTo = ''
    let fromName = 'NexaFlow'

    if (conversation_id) {
      try {
        const convRes = await fetch(
          `${supabaseUrl}/rest/v1/conversations?id=eq.${conversation_id}&select=business_id`,
          {
            headers: {
              'apikey': serviceRoleKey,
              'Authorization': `Bearer ${serviceRoleKey}`,
            },
          }
        )
        const convRows = await convRes.json()
        const businessId = convRows?.[0]?.business_id

        if (businessId) {
          const bizRes = await fetch(
            `${supabaseUrl}/rest/v1/businesses?id=eq.${businessId}&select=owner_email,business_name`,
            {
              headers: {
                'apikey': serviceRoleKey,
                'Authorization': `Bearer ${serviceRoleKey}`,
              },
            }
          )
          const bizRows = await bizRes.json()
          if (bizRows?.[0]?.owner_email) {
            replyTo = bizRows[0].owner_email
          }
          if (bizRows?.[0]?.business_name) {
            fromName = bizRows[0].business_name
          }
        }
      } catch (lookupErr) {
        console.error('Business reply-to lookup failed:', lookupErr)
        // Fall through — send without reply-to rather than failing the send
      }
    }

    const mgForm = new URLSearchParams()
    mgForm.append('from', `${fromName} <no-reply@${MAILGUN_DOMAIN}>`)
    mgForm.append('to', to)
    mgForm.append('subject', subject ?? '')
    mgForm.append('html', body)
    if (replyTo) {
      mgForm.append('h:Reply-To', replyTo)
    }

    const mgRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: mgForm.toString(),
    })

    if (!mgRes.ok) {
      const mgErr = await mgRes.text()
      console.error('Mailgun send error:', mgErr)
      return new Response(
        JSON.stringify({ error: 'Failed to send email' }),
        { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    return new Response(
      JSON.stringify({ error: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})