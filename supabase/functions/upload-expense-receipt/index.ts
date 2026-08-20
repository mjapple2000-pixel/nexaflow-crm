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

    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
    const serviceKey = secretKeys.nexaflow_service_role_2026_08 ?? ''

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

    const adminClient = createClient(supabaseUrl, serviceKey)

    const contentType = req.headers.get('content-type') ?? ''
    if (!contentType.includes('multipart/form-data')) {
      return new Response(JSON.stringify({ error: 'Expected multipart/form-data' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const formData = await req.formData()
    const expense_id = formData.get('expense_id')
    const receipt = formData.get('receipt') as File | null

    if (!expense_id || !receipt || receipt.size === 0) {
      return new Response(JSON.stringify({ error: 'expense_id and receipt file are required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Resolve caller's business_id and confirm they own this expense
    const { data: profile } = await userClient
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .maybeSingle()

    const { data: expense } = await adminClient
      .from('job_expenses')
      .select('business_id')
      .eq('id', Number(expense_id))
      .maybeSingle()

    if (!expense) {
      return new Response(JSON.stringify({ error: 'Expense not found' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const isSuperuser = user.email === 'vantagecaretech@gmail.com'
    if (!isSuperuser && (!profile || profile.business_id !== expense.business_id)) {
      return new Response(JSON.stringify({ error: 'Access denied' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const ext = receipt.name.split('.').pop() ?? 'jpg'
    const fileName = `${expense.business_id}/${expense_id}/${Date.now()}.${ext}`
    const arrayBuf = await receipt.arrayBuffer()

    const { error: uploadError } = await adminClient.storage
      .from('job-expense-receipts')
      .upload(fileName, arrayBuf, {
        contentType: receipt.type,
        upsert: false,
      })

    if (uploadError) {
      console.error('Receipt upload error:', uploadError.message)
      return new Response(JSON.stringify({ error: `Upload failed: ${uploadError.message}` }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const { error: updateError } = await adminClient
      .from('job_expenses')
      .update({ receipt_photo_path: fileName })
      .eq('id', Number(expense_id))

    if (updateError) {
      console.error('Update error:', updateError.message)
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    console.log('Receipt uploaded for expense:', expense_id, '| path:', fileName)

    return new Response(
      JSON.stringify({ success: true, receipt_photo_path: fileName }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('upload-expense-receipt error:', String(err))
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})