import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? ''

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

// Migrated from the "NexaFlow Daily Ticket Digest" Make scenario.
// Two OpenAI calls preserved: (1) per-ticket suggested-fix, run once per
// unresolved ticket, written back to ai_suggested_fix; (2) one platform-wide
// analysis call over all tickets together, producing the HTML digest body.
// Superuser-only email, no business_id scoping — matches original.
//
// Bug fixed during migration: the original Make PATCH URL was
// `id=eq. {{11.id}}` (stray space after "eq."), which likely caused every
// per-ticket ai_suggested_fix write to silently match zero rows. Using the
// supabase-js client instead of a raw PATCH URL avoids that class of bug.
//
// Behavior change from the original (explicit decision, not a migration
// artifact): the digest email is now ONLY sent when there's something to
// report — ticket_count > 0 or a fix_error occurred. The original always
// sent, even with zero tickets. Every run still logs to cron_run_log
// regardless of whether an email went out, so cron-heartbeat can detect if
// this function silently stops running altogether.

async function callOpenAI(messages: { role: string; content: string }[], maxTokens: number) {
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'gpt-4o-mini',
      max_tokens: maxTokens,
      temperature: 1,
      top_p: 1,
      messages,
    }),
  })
  if (!res.ok) {
    const bodyText = await res.text()
    throw new Error(`OpenAI error ${res.status}: ${bodyText}`)
  }
  const json = await res.json()
  return json.choices?.[0]?.message?.content?.trim() ?? ''
}

function buildEmailHtml(digestHtml: string, dateLabel: string) {
  return `<div style="font-family: sans-serif; max-width: 700px; margin: 0 auto; color: #1a1a2e;">

  <div style="background: linear-gradient(135deg, #6C63FF, #4F46E5); padding: 28px 32px; border-radius: 12px 12px 0 0;">
    <h1 style="color: white; margin: 0; font-size: 22px;">Ticket Support Digest</h1>
    <p style="color: rgba(255,255,255,0.8); margin: 6px 0 0; font-size: 14px;">${dateLabel} · 10:00 AM</p>
  </div>

  <div style="background: #f8f8ff; padding: 24px 32px; border: 1px solid #e5e7eb; border-top: none;">

    <p style="font-size: 14px; color: #6b7280; margin-top: 0;">
      Below is your AI-generated analysis of all unresolved support tickets.
      Priority and fix recommendations are provided for each.
    </p>

${digestHtml}
  </div>

  <div style="background: #1e1b4b; padding: 16px 32px; border-radius: 0 0 12px 12px; text-align: center;">
    <p style="color: rgba(255,255,255,0.5); font-size: 11px; margin: 0;">
      VantageCareTech · This digest is generated automatically each morning at 10 AM EST
    </p>
  </div>

</div>`
}

async function logRun(success: boolean, detail: Record<string, unknown>) {
  try {
    await supabase.from('cron_run_log').insert({
      function_name: 'daily-ticket-digest',
      success,
      detail,
    })
  } catch (e) {
    console.error('Failed to write cron_run_log:', e)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const providedSecret = req.headers.get('x-cron-secret') ?? ''
    if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // ── 1. Fetch all unresolved tickets ────────────────────────────
    const { data: tickets, error } = await supabase
      .from('support_tickets')
      .select('id, business_id, category, category_other, description, status, inserted_at, businesses(business_name)')
      .neq('status', 'resolved')
      .order('inserted_at', { ascending: true })

    if (error) throw error

    // ── 2. Per-ticket suggested fix (OpenAI call #1, once per ticket) ───
    let fixesWritten = 0
    const fixErrors: string[] = []

    for (const ticket of tickets ?? []) {
      try {
        const fix = await callOpenAI(
          [
            {
              role: 'system',
              content: 'You are a helpful support assistant. Given a support ticket description, provide a concise suggested fix or resolution in 2-3 sentences.',
            },
            { role: 'user', content: ticket.description ?? '' },
          ],
          300,
        )

        const { error: updateError } = await supabase
          .from('support_tickets')
          .update({ ai_suggested_fix: fix })
          .eq('id', ticket.id)

        if (updateError) throw updateError
        fixesWritten++
      } catch (e) {
        fixErrors.push(`Ticket ${ticket.id}: ${(e as Error).message}`)
      }
    }

    const ticketCount = tickets?.length ?? 0

    // ── 3. If nothing to report and nothing failed, log and stop ─────
    if (ticketCount === 0 && fixErrors.length === 0) {
      await logRun(true, { ticket_count: 0, fixes_written: 0, fix_errors: [], email_sent: false, reason: 'no_unresolved_tickets' })
      return new Response(
        JSON.stringify({ ticket_count: 0, fixes_written: 0, fix_errors: [], email_sent: false }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── 4. Aggregate all tickets into one text blob ──────────────
    const aggregated = (tickets ?? [])
      .map((t: any) =>
        `Ticket ID: ${t.id} | Business: ${t.businesses?.business_name ?? 'Unknown'} | Category: ${t.category ?? ''} | Other: ${t.category_other ?? ''} | Description: ${t.description ?? ''} | Status: ${t.status} | Submitted: ${t.inserted_at}`
      )
      .join('')

    // ── 5. Platform-wide digest analysis (OpenAI call #2, once) ─────
    const digestPrompt = `Here are all unresolved NexaFlow support tickets. Analyze ONLY these tickets, do not invent any:\n\n${aggregated}`

    const digestHtml = await callOpenAI(
      [
        {
          role: 'system',
          content:
            'You are a senior software engineer and support analyst for NexaFlow, a Flutter Web + Supabase SaaS CRM platform for home service businesses. Analyze ONLY the tickets provided — do not invent any. For each ticket: 1) Assign priority (high/medium/low). 2) Provide a specific fix recommendation. 3) Note if customer-specific or platform-wide. Format as clean HTML with a card per ticket, color-coded priority badges: red=high, orange=medium, blue=low. Return only the HTML, no markdown, no code fences, no explanation outside the HTML. ' +
            digestPrompt,
        },
        { role: 'user', content: digestPrompt },
      ],
      2048,
    )

    // ── 6. Email the digest via Mailgun ───────────────────
    const now = new Date()
    const dateLabel = now.toLocaleDateString('en-US', {
      timeZone: 'America/New_York', weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
    })
    const subjectDateLabel = now.toLocaleDateString('en-US', {
      timeZone: 'America/New_York', month: 'long', day: 'numeric', year: 'numeric',
    })

    const form = new URLSearchParams()
    form.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
    form.append('to', 'vantagecaretech@gmail.com')
    form.append('subject', `Support Digest — ${subjectDateLabel}`)
    form.append('html', buildEmailHtml(digestHtml, dateLabel))

    const mgRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    })

    if (!mgRes.ok) {
      const bodyText = await mgRes.text()
      throw new Error(`Mailgun error: ${bodyText}`)
    }

    const resultPayload = {
      ticket_count: ticketCount,
      fixes_written: fixesWritten,
      fix_errors: fixErrors,
      email_sent: true,
    }

    await logRun(true, resultPayload)

    return new Response(
      JSON.stringify(resultPayload),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('daily-ticket-digest error:', err)
    await logRun(false, { error: (err as Error).message })
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
