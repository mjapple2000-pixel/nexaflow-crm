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
  JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08 ?? '',
)

function formatAppointmentTime(iso: string | null, timezone: string | null): string {
  if (!iso) return 'a time to be confirmed'
  const date = new Date(iso)
  if (isNaN(date.getTime())) return iso
  try {
    return new Intl.DateTimeFormat('en-US', {
      weekday: 'long', month: 'long', day: 'numeric',
      hour: 'numeric', minute: '2-digit', timeZone: timezone || 'America/New_York',
    }).format(date)
  } catch {
    return new Intl.DateTimeFormat('en-US', {
      weekday: 'long', month: 'long', day: 'numeric',
      hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York',
    }).format(date)
  }
}

function buildEmail(
  triggerType: string,
  businessName: string,
  details: { leadName?: string; leadEmail?: string; leadPhone?: string; leadAddress?: string; appointmentTimeFormatted?: string },
): { subject: string; text: string } {
  const lines: string[] = []

  if (triggerType === 'appointment_booked') {
    lines.push(`A new appointment was just booked with ${businessName}. Here's what you need to know:`)
    lines.push('')
    if (details.appointmentTimeFormatted) lines.push(`When: ${details.appointmentTimeFormatted}`)
    if (details.leadName) lines.push(`Name: ${details.leadName}`)
    if (details.leadEmail) lines.push(`Email: ${details.leadEmail}`)
    if (details.leadPhone) lines.push(`Phone: ${details.leadPhone}`)
    if (details.leadAddress) lines.push(`Address: ${details.leadAddress}`)
    return { subject: '📅 New Appointment Booked', text: [...lines, '', `— ${businessName}`].join('\n') }
  }

  if (triggerType === 'new_lead') {
    lines.push(`You've got a new lead for ${businessName}! Here are the details:`)
    lines.push('')
    if (details.leadName) lines.push(`Name: ${details.leadName}`)
    if (details.leadEmail) lines.push(`Email: ${details.leadEmail}`)
    if (details.leadPhone) lines.push(`Phone: ${details.leadPhone}`)
    if (details.leadAddress) lines.push(`Address: ${details.leadAddress}`)
    return { subject: '🔔 New Lead Received', text: [...lines, '', `— ${businessName}`].join('\n') }
  }

  lines.push(`Something new just happened for ${businessName}.`)
  lines.push('')
  if (details.leadName) lines.push(`Name: ${details.leadName}`)
  if (details.leadEmail) lines.push(`Email: ${details.leadEmail}`)
  if (details.leadPhone) lines.push(`Phone: ${details.leadPhone}`)
  if (details.leadAddress) lines.push(`Address: ${details.leadAddress}`)
  return { subject: '⚡ Notification', text: [...lines, '', `— ${businessName}`].join('\n') }
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

    const body = await req.json()
    const { trigger_type, business_id, lead_name, lead_email, lead_phone, lead_address, appointment_time } = body

    if (!trigger_type || !business_id) {
      return new Response(JSON.stringify({ error: 'trigger_type and business_id are required' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const { data: business, error: bizErr } = await supabase
      .from('businesses')
      .select('business_name, owner_email, business_email, admin_email, timezone')
      .eq('id', business_id)
      .maybeSingle()

    if (bizErr) throw bizErr
    if (!business) {
      return new Response(JSON.stringify({ error: 'Business not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const ownerEmail = business.owner_email || business.business_email || business.admin_email
    if (!ownerEmail) {
      console.log(`notify-owner: no owner email configured for business ${business_id}, skipping`)
      return new Response(JSON.stringify({ skipped: 'no owner email configured' }), {
        status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const businessName = business.business_name || 'your business'
    const appointmentTimeFormatted = trigger_type === 'appointment_booked'
      ? formatAppointmentTime(appointment_time, business.timezone)
      : undefined

    const { subject, text } = buildEmail(trigger_type, businessName, {
      leadName: lead_name, leadEmail: lead_email, leadPhone: lead_phone,
      leadAddress: lead_address, appointmentTimeFormatted,
    })

    const form = new URLSearchParams()
    form.append('from', `${businessName} <no-reply@${MAILGUN_DOMAIN}>`)
    form.append('to', ownerEmail)
    form.append('subject', subject)
    form.append('text', text)

    const mgRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    })

    if (!mgRes.ok) {
      const mgErr = await mgRes.text()
      console.error('notify-owner Mailgun error:', mgErr)
      return new Response(JSON.stringify({ error: 'Failed to send notification' }), {
        status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    return new Response(JSON.stringify({ sent: true }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('notify-owner error:', err)
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})