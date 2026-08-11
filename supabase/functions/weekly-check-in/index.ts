import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
)

// Exact copy migrated from the "Weekly Check In" Make scenario blueprint —
// only the {{owner_name}} merge field changes per recipient. No AI involved
// in this scenario (unlike Daily Ticket Digest, which has two real OpenAI
// calls and will need those preserved when migrated).
function buildEmailHtml(ownerName: string) {
  return `<p>Hi ${ownerName},</p>

<p>I hope things are going well for you and your business!</p>

<p>I wanted to take a moment to reach out personally — running a small business is no small feat, and I genuinely care about how VantageCareTech is working for you..</p>

<p>A few things I'd love to hear from you:</p>

<p>💬 <strong>How has VantageCareTech been working for your business so far?</strong><br>
💡 <strong>Is there anything that's been confusing, frustrating, or could work better?</strong><br>
⭐ <strong>Are there any features or tools you wish NexaFlow had?</strong></p>

<p>Your feedback directly shapes what we build next. We're a small, dedicated team and every piece of feedback we receive goes straight into our roadmap. No suggestion is too big or too small.</p>

<p>Just hit reply and let me know — I personally read every response.</p>

<p>Thank you for being part of the VantageCareTech community. It means everything to us.</p>

<p>Warmly,</p>

<p>Michael Apple<br>
Founder &amp; Owner, VantageCareTech LLC<br>
vantagecaretech@gmail.com</p>`
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

    const { data: businesses, error } = await supabase
      .from('businesses')
      .select('id, owner_name, owner_email')
      .eq('is_paid', true)

    if (error) throw error

    let sent = 0
    let skipped = 0
    const errors: string[] = []

    for (const biz of businesses ?? []) {
      const ownerEmail = biz.owner_email as string | null
      const ownerName = (biz.owner_name as string | null)?.trim() || 'there'

      if (!ownerEmail) { skipped++; continue }

      try {
        const form = new URLSearchParams()
        // Matches the pattern already established in welcome-email: business
        // name as the display name, not the personal name — was wrongly set
        // to "Michael Apple" here originally, inconsistent with the sibling
        // function. Reply-To still routes replies to the personal inbox.
        form.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
        form.append('to', ownerEmail)
        form.append('h:Reply-To', 'vantagecaretech@gmail.com')
        form.append('subject', 'Checking in — how is VantageCareTech working for you? 👋')
        form.append('html', buildEmailHtml(ownerName))

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
          errors.push(`${ownerEmail}: ${bodyText}`)
        } else {
          sent++
        }
      } catch (e) {
        errors.push(`${ownerEmail}: ${(e as Error).message}`)
      }
    }

    return new Response(
      JSON.stringify({ sent, skipped, total: businesses?.length ?? 0, errors }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('weekly-check-in error:', err)
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})