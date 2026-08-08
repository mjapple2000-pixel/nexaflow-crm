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
    const { email, signup_url } = await req.json()

    if (!email || !signup_url) {
      return new Response(
        JSON.stringify({ error: 'email and signup_url are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!MAILGUN_API_KEY) {
      return new Response(
        JSON.stringify({ error: 'Mailgun is not configured' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const html = `
      <div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:40px 20px;color:#1a1a1a;">
        <h2 style="margin-bottom:8px;">You're invited. 🎉</h2>
        <p style="font-size:16px;color:#444;line-height:1.6;">
          You've been personally invited to join the <strong>BETA program</strong> — free, full access to our CRM platform built for small or large businesses.
        </p>
        <p style="font-size:16px;color:#444;line-height:1.6;">
          No credit card. No catch. Just a front-row seat to help shape the product.
        </p>
        <div style="text-align:center;margin:36px 0;">
          <a href="${signup_url}" style="background:#4f46e5;color:#fff;padding:14px 32px;border-radius:8px;text-decoration:none;font-size:16px;font-weight:600;">
            Claim Your Free Access →
          </a>
        </div>
        <p style="font-size:14px;color:#888;">
          This invite expires in <strong>7 days</strong>. If you weren't expecting this, you can ignore it.
        </p>
        <hr style="border:none;border-top:1px solid #eee;margin:32px 0;">
        <p style="font-size:13px;color:#aaa;text-align:center;">
          The VantageCareTech LLC Team
        </p>
      </div>
    `

    const mgForm = new URLSearchParams()
    mgForm.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
    mgForm.append('to', email)
    mgForm.append('subject', "You're invited to try our CRM — claim your free access")
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
        JSON.stringify({ error: 'Failed to send invite email' }),
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