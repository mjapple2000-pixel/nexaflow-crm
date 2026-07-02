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
    const { email, full_name, phone, role, permissions, business_id, business_name } = await req.json()

    if (!email || !business_id) {
      return new Response(
        JSON.stringify({ error: 'email and business_id are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // ── Step 1: Generate magic invite link ───────────────────────────────────
    const linkRes = await fetch(`${supabaseUrl}/auth/v1/admin/generate_link`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': serviceRoleKey,
        'Authorization': `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        type: 'invite',
        email,
        options: {
          redirect_to: 'https://nexaflow.app/login',
        },
      }),
    })

    const linkData = await linkRes.json()
    console.log('generate_link response:', JSON.stringify(linkData))

    // Try all known field paths Supabase might return the link in
    const inviteLink =
      linkData?.action_link ??
      linkData?.properties?.action_link ??
      linkData?.data?.properties?.action_link ??
      linkData?.hashed_token ??
      ''

    console.log('inviteLink resolved to:', inviteLink)

    if (!linkRes.ok) {
      const isAlreadyRegistered =
        JSON.stringify(linkData).toLowerCase().includes('already registered')
      if (!isAlreadyRegistered) {
        return new Response(
          JSON.stringify({ error: linkData?.msg || linkData?.message || 'Failed to generate invite link' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    }

    // ── Step 2: Insert pending profile row ───────────────────────────────────
    const profileRes = await fetch(`${supabaseUrl}/rest/v1/profiles`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': serviceRoleKey,
        'Authorization': `Bearer ${serviceRoleKey}`,
        'Prefer': 'return=representation',
      },
      body: JSON.stringify({
        business_id,
        email,
        full_name: full_name ?? '',
        phone: phone ?? '',
        role: role ?? 'member',
        permissions: permissions ?? {
          launchpad: false,
          contacts: true,
          pipelines: true,
          appointments: true,
          campaigns: false,
          conversations: true,
          reporting: false,
          forms: false,
          ai_chat: false,
          automations: false,
          settings: false,
        },
        status: 'pending',
        invited_at: new Date().toISOString(),
      }),
    })

    if (!profileRes.ok) {
      const profileErr = await profileRes.json()
      return new Response(
        JSON.stringify({ error: profileErr?.message || 'Failed to create profile' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const profileRows = await profileRes.json()
    const newProfileId = profileRows?.[0]?.id ?? null

    // ── Step 3: Generate employee hub token + text it to the new member ───────
    let hubLink = ''
    if (newProfileId && phone) {
      const hubToken = crypto.randomUUID()

      const tokenRes = await fetch(`${supabaseUrl}/rest/v1/employee_hub_tokens`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': serviceRoleKey,
          'Authorization': `Bearer ${serviceRoleKey}`,
          'Prefer': 'return=minimal',
        },
        body: JSON.stringify({
          token: hubToken,
          profile_id: newProfileId,
          business_id,
        }),
      })

      if (tokenRes.ok) {
        hubLink = `https://nexaflow-crm.web.app/hub/${hubToken}`

        const accountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!
        const authToken   = Deno.env.get('TWILIO_AUTH_TOKEN')!
        const fromPhone   = '+18135500158'

        try {
          await fetch(
            `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
            {
              method: 'POST',
              headers: {
                'Authorization': 'Basic ' + btoa(`${accountSid}:${authToken}`),
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: new URLSearchParams({
                From: fromPhone,
                To: phone,
                Body: `Welcome to ${business_name ?? 'the team'}! Use this link to clock in/out on the go: ${hubLink}`,
              }).toString(),
            }
          )
        } catch (smsErr) {
          console.error('Employee hub SMS send error:', smsErr)
        }
      } else {
        console.error('Failed to create employee hub token:', await tokenRes.text())
      }
    }

    // ── Step 4: Send invite email directly via Mailgun ─────────────────────────
    if (MAILGUN_API_KEY && inviteLink) {
      try {
        const mgForm = new URLSearchParams()
        mgForm.append('from', `${business_name ?? 'NexaFlow'} <no-reply@${MAILGUN_DOMAIN}>`)
        mgForm.append('to', email)
        mgForm.append('subject', `You've been invited to join ${business_name ?? 'NexaFlow'}`)
        mgForm.append('html', `
          <p>Hi ${full_name ?? 'there'},</p>
          <p>You've been invited to join <strong>${business_name ?? 'NexaFlow'}</strong> as a ${role ?? 'member'}.</p>
          <p><a href="${inviteLink}">Click here to set up your account</a></p>
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
        console.error('Mailgun invite send error:', mgErr)
      }
    }

    return new Response(
      JSON.stringify({ success: true, invite_link: inviteLink }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (e) {
    return new Response(
      JSON.stringify({ error: e.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})