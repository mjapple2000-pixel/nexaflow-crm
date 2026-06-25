import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const appDomain = 'https://nexaflow-crm.web.app'

    // Authenticated client — verify the calling staff user
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders })

    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })

    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders })

    // Resolve business_id from profiles
    const adminClient = createClient(supabaseUrl, serviceRoleKey)
    const { data: profile } = await adminClient
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .single()

    if (!profile?.business_id) return new Response(JSON.stringify({ error: 'No business found' }), { status: 400, headers: corsHeaders })

    const businessId = profile.business_id

    // Parse body
    const { lead_id } = await req.json()
    if (!lead_id) return new Response(JSON.stringify({ error: 'lead_id required' }), { status: 400, headers: corsHeaders })

    // Verify lead belongs to this business
    const { data: lead } = await adminClient
      .from('leads')
      .select('id, lead_name, lead_phone, client_access_token, client_portal_last_sent_at')
      .eq('id', lead_id)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .single()

    if (!lead) return new Response(JSON.stringify({ error: 'Lead not found' }), { status: 404, headers: corsHeaders })

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

    // Send SMS via Twilio
    if (lead.lead_phone) {
      const twilioAccountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
      const twilioAuthToken = Deno.env.get('TWILIO_AUTH_TOKEN')!
      const twilioFromNumber = Deno.env.get('TWILIO_PHONE_NUMBER')!

      const digitsOnly = lead.lead_phone.replace(/\D/g, '')
      const toNumber = digitsOnly.startsWith('1') ? `+${digitsOnly}` : `+1${digitsOnly}`

      const { data: business } = await adminClient
        .from('businesses')
        .select('business_name')
        .eq('id', businessId)
        .single()

      const firstName = (lead.lead_name as string)?.split(' ')[0] ?? 'there'
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

    return new Response(
      JSON.stringify({ portal_url: portalUrl, token }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('generate-client-portal-link error:', err)
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500, headers: corsHeaders })
  }
})