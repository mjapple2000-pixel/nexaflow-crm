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
    const { to, owner_name } = await req.json()

    if (!to) {
      return new Response(
        JSON.stringify({ error: 'to is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!MAILGUN_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'Mailgun is not configured' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const ownerName = owner_name ?? 'there'

    const html = `
      <p>Hi ${ownerName},</p>

      <p>Welcome to VantageCareTech — we're really glad you're here.</p>

      <p>Here are your first 4 steps to get up and running:</p>

      <p><strong>1. Complete your Business Profile</strong><br>
      Head to Settings → Business Profile and fill in your business name, address, and contact info. This powers your AI's responses.</p>

      <p><strong>2. Configure your AI Settings</strong><br>
      Go to Settings → AI Settings and set your AI's name, tone, and instructions. This is what your leads will interact with — make it yours.</p>

      <p><strong>3. Build your Knowledge Base</strong><br>
      Go to Settings → Knowledge Base and add your services, FAQs, pricing, and anything else your AI should know about your business.</p>

      <p><strong>4. Head to your Launchpad</strong><br>
      Your Launchpad is your home base. It walks you through everything left to set up — including connecting your phone, email channels, etc. — so nothing gets missed.</p>

      <p>If you run into anything or have questions, just reply to this email — I read every one.</p>

      <p>Looking forward to seeing what you build.</p>

      <p>Michael Apple<br>
      Founder & Owner, VantageCareTech LLC<br>
      vantagecaretech@gmail.com</p>
    `

    const mgForm = new URLSearchParams()
    mgForm.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
    mgForm.append('to', to)
    mgForm.append('subject', "Welcome to Vantagecaretech – Let's Build Something Great Together 🚀")
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
      return new Response(
        JSON.stringify({ error: 'Failed to send welcome email' }),
        { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ success: true }),
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