import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAKE_INVITE_WEBHOOK = Deno.env.get('MAKE_INVITE_WEBHOOK') ?? ''

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { email, full_name, role, permissions, business_id, business_name } = await req.json()

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
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify({
        business_id,
        email,
        full_name: full_name ?? '',
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

    // ── Step 3: Call Make webhook ─────────────────────────────────────────────
    if (MAKE_INVITE_WEBHOOK) {
      await fetch(MAKE_INVITE_WEBHOOK, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to: email,
          full_name: full_name ?? '',
          invite_link: inviteLink,
          business_name: business_name ?? 'NexaFlow',
          role: role ?? 'member',
        }),
      })
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