import { createClient } from 'npm:@supabase/supabase-js@2'

const TWILIO_ACCOUNT_SID = Deno.env.get('TWILIO_ACCOUNT_SID')!
const TWILIO_AUTH_TOKEN = Deno.env.get('TWILIO_AUTH_TOKEN')!
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
const SUPABASE_SERVICE_ROLE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? ''

const twilioAuth = btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`)

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'Missing authorization' }, 401)
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: authHeader } }
    })

    // Resolve business_id server-side — never trust client input
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      return jsonResponse({ error: 'Unauthorized' }, 401)
    }

    const { action, areaCode, phoneNumber, friendlyName, phoneNumberId, business_id: bodyBusinessId } = await req.json()

    // ── Superuser bypass ── same pattern as the Stripe Connect functions.
    // The superuser account (vantagecaretech@gmail.com) has no profiles row
    // by design, so the plain profile lookup below always failed for it —
    // this showed as "No business found for user" whenever tested as superuser.
    const { data: suRow } = await supabase
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle()
    const isSuperuser = !!suRow

    let businessId: number | null = null
    if (isSuperuser) {
      businessId = bodyBusinessId ?? null
      if (!businessId) {
        return jsonResponse({ error: 'business_id is required' }, 400)
      }
    } else {
      const { data: profile } = await supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .single()

      if (!profile?.business_id) {
        return jsonResponse({ error: 'No business found for user' }, 403)
      }
      businessId = profile.business_id
    }

    // ── A2P compliance gate (SMS-01) ── search and purchase are blocked
    // until this business's Twilio A2P brand shows approved. Promoting an
    // already-purchased number to primary, and releasing a number, are
    // never gated — a business that's already approved enough to have
    // bought numbers shouldn't be re-blocked from managing them.
    if (action === 'search' || action === 'purchase') {
      const { data: a2pProfile } = await supabase
        .from('business_a2p_profiles')
        .select('status')
        .eq('business_id', businessId)
        .is('deleted_at', null)
        .maybeSingle()

      if (a2pProfile?.status !== 'approved') {
        return jsonResponse({ error: 'Number requests are disabled until this business\'s A2P brand shows Approved.' }, 403)
      }
    }

    if (action === 'search') {
      if (!areaCode || areaCode.length !== 3) {
        return jsonResponse({ error: 'Valid 3-digit area code required' }, 400)
      }

      const searchUrl = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/AvailablePhoneNumbers/US/Local.json?AreaCode=${areaCode}&SmsEnabled=true&Limit=10`

      const twilioRes = await fetch(searchUrl, {
        headers: { Authorization: `Basic ${twilioAuth}` }
      })

      if (!twilioRes.ok) {
        const err = await twilioRes.text()
        return jsonResponse({ error: 'Twilio search failed', detail: err }, 502)
      }

      const twilioData = await twilioRes.json()

      const results = (twilioData.available_phone_numbers || []).map((n: any) => ({
        phoneNumber: n.phone_number,
        friendlyName: n.friendly_name,
        locality: n.locality,
        region: n.region,
        monthlyCost: '$1.15' // Twilio US local number base rate — static for now, not pulled from a pricing API
      }))

      return jsonResponse({ results })
    }

    if (action === 'purchase') {
      if (!phoneNumber) {
        return jsonResponse({ error: 'phoneNumber required' }, 400)
      }

      // Confirm this business doesn't already have an active number with this exact value (avoid dupes)
      const { data: existing } = await supabase
        .from('phone_numbers')
        .select('id')
        .eq('business_id', businessId)
        .eq('phone_number', phoneNumber)
        .is('deleted_at', null)
        .maybeSingle()

      if (existing) {
        return jsonResponse({ error: 'Number already provisioned for this business' }, 409)
      }

      const purchaseUrl = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/IncomingPhoneNumbers.json`
      const smsWebhookUrl = `${SUPABASE_URL}/functions/v1/receive-sms`

      const body = new URLSearchParams({
        PhoneNumber: phoneNumber,
        SmsUrl: smsWebhookUrl,
        SmsMethod: 'POST',
        FriendlyName: friendlyName || phoneNumber
      })

      const twilioRes = await fetch(purchaseUrl, {
        method: 'POST',
        headers: {
          Authorization: `Basic ${twilioAuth}`,
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body
      })

      if (!twilioRes.ok) {
        const err = await twilioRes.text()
        return jsonResponse({ error: 'Twilio purchase failed', detail: err }, 502)
      }

      const purchased = await twilioRes.json()

      const { data: inserted, error: insertError } = await supabase
        .from('phone_numbers')
        .insert({
          business_id: businessId,
          twilio_sid: purchased.sid,
          phone_number: purchased.phone_number,
          friendly_name: friendlyName || purchased.phone_number,
          status: 'active'
        })
        .select()
        .single()

      if (insertError) {
        return jsonResponse({ error: 'Purchased but failed to save', detail: insertError.message }, 500)
      }

      // Only the FIRST number a business ever gets auto-activates as the
      // single source of truth send-sms/receive-sms key off. Any number
      // purchased after that stays a spare — the business can hold a
      // backup/second line without it silently hijacking which number is
      // actually live — until explicitly promoted via 'set_primary'.
      const { data: currentBiz } = await supabase
        .from('businesses')
        .select('ai_phone_number')
        .eq('id', businessId)
        .single()

      let becamePrimary = false
      if (!currentBiz?.ai_phone_number) {
        const { error: syncError } = await supabase
          .from('businesses')
          .update({ ai_phone_number: purchased.phone_number })
          .eq('id', businessId)
        if (!syncError) becamePrimary = true
      }

      return jsonResponse({ success: true, phoneNumber: inserted, becamePrimary })
    }

    if (action === 'set_primary') {
      if (!phoneNumberId) {
        return jsonResponse({ error: 'phoneNumberId required' }, 400)
      }

      const { data: record } = await supabase
        .from('phone_numbers')
        .select('id, phone_number, status')
        .eq('id', phoneNumberId)
        .eq('business_id', businessId)
        .is('deleted_at', null)
        .single()

      if (!record) {
        return jsonResponse({ error: 'Number not found for this business' }, 404)
      }
      if (record.status !== 'active') {
        return jsonResponse({ error: 'Cannot set a released number as the AI number' }, 400)
      }

      const { error: updateError } = await supabase
        .from('businesses')
        .update({ ai_phone_number: record.phone_number })
        .eq('id', businessId)

      if (updateError) {
        return jsonResponse({ error: 'Failed to update AI phone number', detail: updateError.message }, 500)
      }

      return jsonResponse({ success: true, phoneNumber: record.phone_number })
    }

    if (action === 'release') {
      if (!phoneNumberId) {
        return jsonResponse({ error: 'phoneNumberId required' }, 400)
      }

      const { data: record } = await supabase
        .from('phone_numbers')
        .select('id, twilio_sid, business_id, phone_number')
        .eq('id', phoneNumberId)
        .eq('business_id', businessId)
        .single()

      if (!record) {
        return jsonResponse({ error: 'Number not found for this business' }, 404)
      }

      const releaseUrl = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/IncomingPhoneNumbers/${record.twilio_sid}.json`

      const twilioRes = await fetch(releaseUrl, {
        method: 'DELETE',
        headers: { Authorization: `Basic ${twilioAuth}` }
      })

      if (!twilioRes.ok && twilioRes.status !== 404) {
        const err = await twilioRes.text()
        return jsonResponse({ error: 'Twilio release failed', detail: err }, 502)
      }

      await supabase
        .from('phone_numbers')
        .update({ status: 'released', deleted_at: new Date().toISOString() })
        .eq('id', phoneNumberId)

      // Clear the single-source-of-truth field if this was the number
      // it pointed to — otherwise send-sms would keep trying to send from
      // a number that no longer exists in Twilio. Does NOT auto-promote
      // another remaining number — the business picks explicitly via
      // 'set_primary' if they want a spare to take over.
      const { data: biz } = await supabase
        .from('businesses')
        .select('ai_phone_number')
        .eq('id', businessId)
        .single()

      if (biz?.ai_phone_number === record.phone_number) {
        await supabase
          .from('businesses')
          .update({ ai_phone_number: null })
          .eq('id', businessId)
      }

      return jsonResponse({ success: true })
    }

    return jsonResponse({ error: 'Invalid action' }, 400)

  } catch (e) {
    return jsonResponse({ error: 'Unexpected error', detail: String(e) }, 500)
  }
})