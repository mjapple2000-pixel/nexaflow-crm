import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing auth header' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const supabaseUrl  = Deno.env.get('SUPABASE_URL')  ?? ''
    const anonKey      = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    const secretKeys   = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
    const serviceKey   = secretKeys.nexaflow_service_role_2026_08 ?? ''

    // User-scoped client — validates the JWT and respects RLS
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Invalid token' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Service-role client — used for storage upload + insert
    const adminClient = createClient(supabaseUrl, serviceKey)

    // ── Parse multipart form data ─────────────────────────────────────────────
    const contentType = req.headers.get('content-type') ?? ''
    if (!contentType.includes('multipart/form-data')) {
      return new Response(JSON.stringify({ error: 'Expected multipart/form-data' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const formData       = await req.formData()
    const business_id    = formData.get('business_id')
    const category       = formData.get('category')
    const category_other = formData.get('category_other') ?? null
    const description    = formData.get('description')
    const attachment     = formData.get('attachment') as File | null

    if (!business_id || !category || !description) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // ── Upload attachment if present ──────────────────────────────────────────
    let attachment_path: string | null = null

    if (attachment && attachment.size > 0) {
      // Server-side allowlist — never trust the client-declared attachment.type
      // or filename extension as-is. Without this, someone could upload HTML
      // or a script-bearing SVG labeled as a screenshot, which Supabase
      // Storage would later serve back with that same attacker-chosen
      // content-type — a stored-XSS-via-file-upload risk for whoever
      // reviews this ticket's attachment later.
      const ALLOWED_ATTACHMENT_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf']
      const ALLOWED_ATTACHMENT_EXTENSIONS = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'pdf']

      if (!ALLOWED_ATTACHMENT_TYPES.includes(attachment.type)) {
        return new Response(JSON.stringify({ error: `Unsupported file type: ${attachment.type || 'unknown'}. Only images and PDFs are allowed.` }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }
      const ext = (attachment.name.split('.').pop() ?? '').toLowerCase()
      if (!ALLOWED_ATTACHMENT_EXTENSIONS.includes(ext)) {
        return new Response(JSON.stringify({ error: `Unsupported file extension: .${ext}` }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const fileName  = `${user.id}/${Date.now()}.${ext}`
      const arrayBuf  = await attachment.arrayBuffer()

      const { error: uploadError } = await adminClient.storage
        .from('ticket-attachments')
        .upload(fileName, arrayBuf, {
          contentType: attachment.type,
          upsert: false,
        })

      if (uploadError) {
        console.error('Attachment upload error:', uploadError.message)
        return new Response(JSON.stringify({ error: `Attachment upload failed: ${uploadError.message}` }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      attachment_path = fileName
    }

    // ── Insert ticket ─────────────────────────────────────────────────────────
    const { data: ticket, error: insertError } = await adminClient
      .from('support_tickets')
      .insert({
        business_id:    Number(business_id),
        submitted_by:   user.id,
        category:       category,
        category_other: category === 'Other' ? category_other : null,
        description:    description,
        attachment_path: attachment_path,
        status:         'open',
      })
      .select('id')
      .single()

    if (insertError) {
      console.error('Insert error:', insertError.message)
      return new Response(JSON.stringify({ error: insertError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    console.log('Ticket created:', ticket.id, '| business:', business_id, '| category:', category)

    return new Response(
      JSON.stringify({ success: true, ticket_id: ticket.id }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('submit-ticket error:', String(err))
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})