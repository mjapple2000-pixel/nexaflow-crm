import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08
const GOOGLE_CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID') ?? ''
const GOOGLE_CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET') ?? ''

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)

// ── Base64url helper (same as gmail-inbound-webhook) ──────────────────────
function encodeBase64Url(str: string): string {
  const bytes = new TextEncoder().encode(str)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

// ── Same refresh pattern as gmail-inbound-webhook / gmail-watch-renew ──────
async function getFreshAccessToken(connection: {
  id: number;
  access_token_secret_id: string;
  refresh_token_secret_id: string;
  token_expires_at: string;
}): Promise<string | null> {
  const expiresAt = new Date(connection.token_expires_at).getTime()
  if (expiresAt > Date.now() + 2 * 60 * 1000) {
    const { data: accessToken } = await supabase.rpc('qb_vault_read_secret', {
      p_id: connection.access_token_secret_id,
    })
    return accessToken ?? null
  }
  const { data: refreshToken } = await supabase.rpc('qb_vault_read_secret', {
    p_id: connection.refresh_token_secret_id,
  })
  if (!refreshToken) return null
  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
    }),
  })
  if (!tokenResp.ok) {
    console.error('outbound-email-send: Gmail token refresh failed:', await tokenResp.text())
    return null
  }
  const tokens = await tokenResp.json()
  await supabase.rpc('qb_vault_update_secret', { p_id: connection.access_token_secret_id, p_secret: tokens.access_token })
  await supabase
    .from('oauth_connections')
    .update({ token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(), updated_at: new Date().toISOString() })
    .eq('id', connection.id)
  return tokens.access_token
}

// ── Send via Gmail API, threaded into the existing conversation ───────────
async function sendViaGmail(opts: {
  accessToken: string;
  fromAddress: string;
  fromName: string;
  toAddress: string;
  subject: string;
  html: string;
  threadId?: string;
  inReplyToMessageId?: string;
}): Promise<boolean> {
  const headerLines = [
    `To: ${opts.toAddress}`,
    `From: ${opts.fromName} <${opts.fromAddress}>`,
    `Subject: ${opts.subject}`,
    `Content-Type: text/html; charset="UTF-8"`,
  ]
  if (opts.inReplyToMessageId) {
    headerLines.push(`In-Reply-To: ${opts.inReplyToMessageId}`)
    headerLines.push(`References: ${opts.inReplyToMessageId}`)
  }
  const raw = encodeBase64Url(`${headerLines.join('\r\n')}\r\n\r\n${opts.html}`)

  const res = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
    method: 'POST',
    headers: { Authorization: `Bearer ${opts.accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ raw, threadId: opts.threadId }),
  })
  if (!res.ok) {
    console.error('outbound-email-send: Gmail send failed:', await res.text())
    return false
  }
  return true
}

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

    let replyTo = ''
    let fromName = 'NexaFlow'
    let businessId: number | null = null
    let resolvedSubject = subject ?? 'Message from NexaFlow'

    if (conversation_id) {
      try {
        const convRes = await fetch(
          `${SUPABASE_URL}/rest/v1/conversations?id=eq.${conversation_id}&select=business_id`,
          { headers: { 'apikey': SERVICE_ROLE_KEY } }
        )
        const convRows = await convRes.json()
        businessId = convRows?.[0]?.business_id ?? null

        if (businessId) {
          const bizRes = await fetch(
            `${SUPABASE_URL}/rest/v1/businesses?id=eq.${businessId}&select=owner_email,dedicated_email,business_name`,
            { headers: { 'apikey': SERVICE_ROLE_KEY } }
          )
          const bizRows = await bizRes.json()
          // Reply-To must be the business's dedicated inbound address, not
          // owner_email — a customer hitting "reply" needs to land back in
          // Mailgun's inbound pipeline (receive-email) so the thread stays
          // in Conversations. Found 9/12: an approved EM-06 draft reply set
          // Reply-To to owner_email, so the customer's reply silently landed
          // in the business owner's personal inbox instead of NexaFlow.
          if (bizRows?.[0]?.dedicated_email) replyTo = bizRows[0].dedicated_email
          else if (bizRows?.[0]?.owner_email) replyTo = bizRows[0].owner_email
          if (bizRows?.[0]?.business_name) fromName = bizRows[0].business_name
        }
      } catch (lookupErr) {
        console.error('Business reply-to lookup failed:', lookupErr)
      }

      // ── Resolve the subject as "Re: <original>", threaded off the actual
      // conversation — never the generic hardcoded product-name subject. ──
      resolvedSubject = subject ?? `Message from ${fromName}`
      try {
        const { data: subjectSource } = await supabase
          .from('messages')
          .select('subject')
          .eq('conversation_id', conversation_id)
          .eq('direction', 'inbound')
          .not('subject', 'is', null)
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle()
        if (subjectSource?.subject) {
          const cleaned = subjectSource.subject.replace(/^(re:\s*)+/i, '').trim()
          resolvedSubject = `Re: ${cleaned}`
        }
      } catch (subjErr) {
        console.error('outbound-email-send: subject lookup failed:', subjErr)
      }

      // ── Gmail-sourced conversation? Route through Gmail so the reply comes
      // from the same address the contact actually emailed, threaded correctly. ──
      try {
        const { data: lastInbound } = await supabase
          .from('messages')
          .select('email_source, external_thread_id, external_message_id')
          .eq('conversation_id', conversation_id)
          .eq('direction', 'inbound')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle()

        if (lastInbound?.email_source === 'gmail' && businessId) {
          const { data: connection } = await supabase
            .from('oauth_connections')
            .select('id, connected_account_email, access_token_secret_id, refresh_token_secret_id, token_expires_at')
            .eq('business_id', businessId)
            .eq('provider', 'gmail')
            .eq('connection_status', 'active')
            .is('deleted_at', null)
            .maybeSingle()

          if (connection) {
            const accessToken = await getFreshAccessToken(connection)
            if (accessToken) {
              let inReplyToMessageId: string | undefined
              if (lastInbound.external_message_id) {
                const metaResp = await fetch(
                  `https://gmail.googleapis.com/gmail/v1/users/me/messages/${lastInbound.external_message_id}?format=metadata&metadataHeaders=Message-ID`,
                  { headers: { Authorization: `Bearer ${accessToken}` } }
                )
                if (metaResp.ok) {
                  const metaJson = await metaResp.json()
                  const midHeader = (metaJson.payload?.headers ?? []).find((h: any) => h.name.toLowerCase() === 'message-id')
                  inReplyToMessageId = midHeader?.value
                }
              }

              const sent = await sendViaGmail({
                accessToken,
                fromAddress: connection.connected_account_email,
                fromName,
                toAddress: to,
                subject: resolvedSubject,
                html: body,
                threadId: lastInbound.external_thread_id ?? undefined,
                inReplyToMessageId,
              })

              if (sent) {
                return new Response(
                  JSON.stringify({ success: true, via: 'gmail' }),
                  { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
                )
              }
              console.error('outbound-email-send: Gmail send failed, falling back to Mailgun')
            }
          }
        }
      } catch (gmailErr) {
        console.error('outbound-email-send: Gmail routing check failed:', gmailErr)
      }
    }

    if (!MAILGUN_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'Mailgun is not configured' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const mgForm = new URLSearchParams()
    mgForm.append('from', `${fromName} <no-reply@${MAILGUN_DOMAIN}>`)
    mgForm.append('to', to)
    mgForm.append('subject', resolvedSubject)
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
      JSON.stringify({ success: true, via: 'mailgun' }),
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