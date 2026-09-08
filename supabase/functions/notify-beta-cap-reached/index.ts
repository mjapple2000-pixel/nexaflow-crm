import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

// Notifies a beta business's owner once per billing period when their AI
// usage has hit the Pro-equivalent cap (2,500 msgs/mo) with no card on file,
// so the AI has paused. Fire-and-forget, called from receive-sms/
// receive-email/ai-chat the moment a conversation actually gets paused for
// this reason. Deduped via business_usage.beta_cap_notified_at — safe to
// call multiple times per business per period, only the first send fires.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { business_id } = await req.json()
    if (!business_id) {
      return new Response(JSON.stringify({ error: 'business_id is required' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const { data: business } = await supabase
      .from('businesses')
      .select('id, business_name, owner_email, owner_name, is_beta, beta_card_added')
      .eq('id', business_id)
      .maybeSingle()

    if (!business || !business.is_beta || business.beta_card_added || !business.owner_email) {
      return new Response(JSON.stringify({ sent: false, reason: 'not applicable' }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const period = new Date()
    period.setUTCDate(1)
    const periodStart = period.toISOString().slice(0, 10)

    const { data: usageRow } = await supabase
      .from('business_usage')
      .select('id, ai_messages_used, ai_messages_included, beta_cap_notified_at')
      .eq('business_id', business_id)
      .eq('period_start', periodStart)
      .maybeSingle()

    if (!usageRow || usageRow.beta_cap_notified_at) {
      return new Response(JSON.stringify({ sent: false, reason: 'already notified or no usage row' }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (!MAILGUN_API_KEY) {
      console.error('MAILGUN_API_KEY not set')
      return new Response(JSON.stringify({ error: 'Mailgun is not configured' }), {
        status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const ownerName = business.owner_name ?? 'there'
    const included = usageRow.ai_messages_included ?? 2500

    const html = `
      <p>Hi ${ownerName},</p>

      <p>Your team's AI assistant has used all ${included} AI messages included with your beta account this month, so it's paused replying for now — no messages have been lost, and everything picks back up automatically once you add a payment method.</p>

      <p>As a beta tester, you're not being charged anything today. Adding a card just lets the AI keep going past your included ${included} messages, billed the same way a paying Pro customer would be: $0.15 per message over the limit, only for what you actually use.</p>

      <p>You can add a card any time in Settings → Billing.</p>

      <p>Questions? Just reply to this email — I read every one.</p>

      <p>Michael Apple<br>
      Founder & Owner, VantageCareTech LLC<br>
      vantagecaretech@gmail.com</p>
    `

    const mgForm = new URLSearchParams()
    mgForm.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
    mgForm.append('to', business.owner_email)
    mgForm.append('subject', 'Your AI assistant has paused — add a card to keep it running')
    mgForm.append('html', html)
    mgForm.append('h:Reply-To', 'vantagecaretech@gmail.com')

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
      return new Response(JSON.stringify({ error: 'Failed to send notification email' }), {
        status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    await supabase
      .from('business_usage')
      .update({ beta_cap_notified_at: new Date().toISOString() })
      .eq('id', usageRow.id)

    return new Response(JSON.stringify({ sent: true }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e)
    console.error('notify-beta-cap-reached error:', message)
    return new Response(JSON.stringify({ error: message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})