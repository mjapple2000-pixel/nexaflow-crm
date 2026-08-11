const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

// Exact copy migrated from the "NexaFlow Beta Daily Email" Make scenario
// blueprint — only {{first_name}} changes per recipient. No AI involved.
function buildEmailHtml(firstName: string) {
  return `<p>Hi ${firstName}!</p>

<p>Hope this is already saving you some serious time out there!</p>

<p>As one of our Beta testers, your feedback means everything to us — you're helping shape what this becomes. So I have one quick question:</p>

<p><strong>What's one thing you'd change or add to make it even better for your business?</strong></p>

<p>Just hit reply and let me know. I read every single response personally.</p>

<p>Thanks for being part of this early,<br>
<strong>Mike</strong><br>
Vantagecaretech LLC
Founder</p>`
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

    // Reuse the existing beta-users function for the recipient list rather
    // than duplicating its query — matches the original Make scenario,
    // which also called this same endpoint.
    const betaRes = await fetch(`${SUPABASE_URL}/functions/v1/beta-users`)
    if (!betaRes.ok) {
      throw new Error(`beta-users fetch failed: ${betaRes.status}`)
    }
    const betaBody = await betaRes.json()
    const recipients: Array<{ first_name: string; email: string; business_name: string }> = betaBody.recipients ?? []

    let sent = 0
    let skipped = 0
    const errors: string[] = []

    for (const r of recipients) {
      if (!r.email) { skipped++; continue }

      try {
        const form = new URLSearchParams()
        form.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
        form.append('to', r.email)
        form.append('h:Reply-To', 'vantagecaretech@gmail.com')
        form.append('subject', 'Quick question from the team 👋')
        form.append('html', buildEmailHtml(r.first_name || 'there'))

        const res = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
          method: 'POST',
          headers: {
            'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: form.toString(),
        })

        if (!res.ok) {
          const bodyText = await res.text()
          errors.push(`${r.email}: ${bodyText}`)
        } else {
          sent++
        }
      } catch (e) {
        errors.push(`${r.email}: ${(e as Error).message}`)
      }
    }

    return new Response(
      JSON.stringify({ sent, skipped, total: recipients.length, errors }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('beta-daily-email error:', err)
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})