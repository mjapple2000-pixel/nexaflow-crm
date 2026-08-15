import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
    const serviceRoleKey = secretKeys.nexaflow_service_role_2026_08 ?? ''
    const appDomain = 'https://nexaflow-crm.web.app'

    // Authenticated client — verify the calling staff user
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders })

    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })

    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders })

    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    // Parse body — channel defaults to 'sms' so existing callers keep working unchanged
    const { lead_id, channel, business_id: bodyBusinessId } = await req.json()
    if (!lead_id) return new Response(JSON.stringify({ error: 'lead_id required' }), { status: 400, headers: corsHeaders })
    const sendChannel = channel === 'email' ? 'email' : 'sms'

    // ── Superuser bypass ── same pattern as the Stripe Connect functions.
    // The superuser account (vantagecaretech@gmail.com) has no profiles row
    // by design, so the plain profile lookup below always failed for it —
    // this showed as "No business found" whenever tested as superuser.
    const { data: suRow } = await adminClient
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const isSuperuser = !!suRow

    let businessId: number | null = null
    if (isSuperuser) {
      businessId = bodyBusinessId ?? null
      if (!businessId) {
        return new Response(JSON.stringify({ error: 'business_id is required' }), { status: 400, headers: corsHeaders })
      }
    } else {
      const { data: profile } = await adminClient
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .single()

      if (!profile?.business_id) return new Response(JSON.stringify({ error: 'No business found' }), { status: 400, headers: corsHeaders })
      businessId = profile.business_id
    }

    // Verify lead belongs to this business
    const { data: lead } = await adminClient
      .from('leads')
      .select('id, lead_name, lead_phone, lead_email, client_access_token, client_portal_last_sent_at')
      .eq('id', lead_id)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .single()

    if (!lead) return new Response(JSON.stringify({ error: 'Lead not found' }), { status: 404, headers: corsHeaders })

    if (sendChannel === 'email' && !lead.lead_email) {
      return new Response(JSON.stringify({ error: 'This lead has no email address on file.' }), { status: 400, headers: corsHeaders })
    }
    if (sendChannel === 'sms' && !lead.lead_phone) {
      return new Response(JSON.stringify({ error: 'This lead has no phone number on file.' }), { status: 400, headers: corsHeaders })
    }

    // Generate token if not already set
    let token = lead.client_access_token
    if (!token) {
      const bytes = new Uint8Array(32)
      crypto.getRandomValues(bytes)
      token = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('')

      await adminClient
        .from('leads')
        .update({ client_access_token: token })
        .eq('id', lead_id)
    }

    // Update last_sent_at
    await adminClient
      .from('leads')
      .update({ client_portal_last_sent_at: new Date().toISOString() })
      .eq('id', lead_id)

    const portalUrl = `${appDomain}/client/${token}`

    const { data: business } = await adminClient
      .from('businesses')
      .select('business_name')
      .eq('id', businessId)
      .single()

    const firstName = (lead.lead_name as string)?.split(' ')[0] ?? 'there'

    // ── SMS via Twilio (unchanged from original) ──
    if (sendChannel === 'sms' && lead.lead_phone) {
      const twilioAccountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
      const twilioAuthToken = Deno.env.get('TWILIO_AUTH_TOKEN')!
      const twilioFromNumber = Deno.env.get('TWILIO_PHONE_NUMBER')!

      const digitsOnly = lead.lead_phone.replace(/\D/g, '')
      const toNumber = digitsOnly.startsWith('1') ? `+${digitsOnly}` : `+1${digitsOnly}`

      const smsBody = `Hi ${firstName}! ${business?.business_name ?? 'Your service provider'} has shared your client portal with you. View your appointments, quotes, and invoices here: ${portalUrl}`

      await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Basic ${btoa(`${twilioAccountSid}:${twilioAuthToken}`)}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: new URLSearchParams({
            From: twilioFromNumber,
            To: toNumber,
            Body: smsBody,
          }).toString(),
        }
      )
    }

    // ── Email via Mailgun (new) ──
    if (sendChannel === 'email' && lead.lead_email) {
      if (MAILGUN_API_KEY) {
        try {
          const mgForm = new URLSearchParams()
          mgForm.append('from', `${business?.business_name ?? 'NexaFlow'} <no-reply@${MAILGUN_DOMAIN}>`)
          mgForm.append('to', lead.lead_email)
          mgForm.append('subject', `Your client portal from ${business?.business_name ?? 'your service provider'}`)
          mgForm.append('html', `
            <p>Hi ${firstName},</p>
            <p>${business?.business_name ?? 'Your service provider'} has shared your client portal with you.</p>
            <p><a href="${portalUrl}">View your appointments, quotes, and invoices here</a></p>
          `)

          await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
            method: 'POST',
            headers: {
              'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: mgForm.toString(),
          })
        } catch (mgErr) {
          console.error('Mailgun portal link send error:', mgErr)
        }
      }
    }

    return new Response(
      JSON.stringify({ portal_url: portalUrl, token, channel: sendChannel }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('generate-client-portal-link error:', err)
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500, headers: corsHeaders })
  }
})