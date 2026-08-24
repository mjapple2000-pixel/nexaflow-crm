import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    secretKeys.nexaflow_service_role_2026_08 ?? ''
  )

  // Resolves a referral code against leads today. Kept as a lookup helper
  // so a later 'contact' referrer_type (B2B) is a one-line addition here,
  // not a rewrite.
  async function findReferrer(code: string) {
    const { data } = await supabase
      .from('leads')
      .select('id, lead_name, business_id, businesses(business_name)')
      .eq('referral_code', code)
      .is('deleted_at', null)
      .maybeSingle()
    if (data) return { type: 'lead' as const, row: data }
    return null
  }

  try {
    // ── GET: preview a referral code before the visitor fills out the form ──
    if (req.method === 'GET') {
      const url = new URL(req.url)
      const code = url.searchParams.get('code')

      if (!code) {
        return new Response(
          JSON.stringify({ valid: false, message: 'This referral link is no longer active.' }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }

      const referrer = await findReferrer(code)

      if (!referrer) {
        return new Response(
          JSON.stringify({ valid: false, message: 'This referral link is no longer active.' }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }

      const firstName = (referrer.row.lead_name as string | null)?.split(' ')[0] ?? null

      return new Response(
        JSON.stringify({
          valid: true,
          referrer_first_name: firstName,
          business_name: (referrer.row as any).businesses?.business_name ?? null,
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // ── POST: submit the referral signup form ──
    const { referral_code, name, email, phone } = await req.json()

    if (!referral_code || !name || !email || !phone) {
      return new Response(
        JSON.stringify({ success: false, message: 'referral_code, name, email, and phone are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ success: false, message: 'Invalid email address' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const phoneRegex = /^[\d\s\-\(\)\+]{7,20}$/
    if (!phoneRegex.test(phone)) {
      return new Response(
        JSON.stringify({ success: false, message: 'Invalid phone number' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const referrer = await findReferrer(referral_code)

    if (!referrer) {
      return new Response(
        JSON.stringify({ success: false, message: 'This referral link is no longer active.' }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const businessId = referrer.row.business_id
    const referrerType = referrer.type
    const referrerId = referrer.row.id

    const digitsOnly = phone.replace(/\D/g, '')
    const normalizedPhone = digitsOnly.startsWith('1') ? `+${digitsOnly}` : `+1${digitsOnly}`

    const { data: existingLead } = await supabase
      .from('leads')
      .select('id, lead_name, lead_email')
      .eq('business_id', businessId)
      .eq('lead_phone', normalizedPhone)
      .is('deleted_at', null)
      .maybeSingle()

    let leadId: number

    if (existingLead) {
      const { error: updateError } = await supabase
        .from('leads')
        .update({
          lead_name: existingLead.lead_name ?? name,
          lead_email: existingLead.lead_email ?? email,
          source: 'referral',
        })
        .eq('id', existingLead.id)

      if (updateError) {
        console.error('Lead update error:', updateError)
        return new Response(
          JSON.stringify({ success: false, message: 'Failed to process referral' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
      leadId = existingLead.id
    } else {
      const { data: newLead, error: insertLeadError } = await supabase
        .from('leads')
        .insert({
          business_id: businessId,
          lead_name: name,
          lead_email: email,
          lead_phone: normalizedPhone,
          lead_status: 'new',
          source: 'referral',
        })
        .select('id')
        .single()

      if (insertLeadError) {
        console.error('Lead insert error:', insertLeadError)
        return new Response(
          JSON.stringify({ success: false, message: 'Failed to process referral' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
      leadId = newLead.id
    }

    const { data: existingReferral } = await supabase
      .from('referrals')
      .select('id')
      .eq('referrer_type', referrerType)
      .eq('referrer_id', referrerId)
      .eq('referred_lead_id', leadId)
      .is('deleted_at', null)
      .maybeSingle()

    if (!existingReferral) {
      const { error: referralInsertError } = await supabase
        .from('referrals')
        .insert({
          business_id: businessId,
          referrer_type: referrerType,
          referrer_id: referrerId,
          referred_lead_id: leadId,
          referral_code: referral_code,
          status: 'lead_created',
        })

      if (referralInsertError) {
        console.error('Referral insert error:', referralInsertError)
        return new Response(
          JSON.stringify({ success: false, message: 'Failed to process referral' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    }

    return new Response(
      JSON.stringify({ success: true, message: 'Thanks! Someone from the team will be in touch soon.' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (err) {
    console.error('handle-referral-signup error:', err)
    return new Response(
      JSON.stringify({ success: false, message: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})