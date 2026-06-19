import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const TWILIO_ACCOUNT_SID = Deno.env.get('TWILIO_ACCOUNT_SID')!
const TWILIO_AUTH_TOKEN = Deno.env.get('TWILIO_AUTH_TOKEN')!
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

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

    const { data: profile } = await supabase
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .single()

    if (!profile?.business_id) {
      return jsonResponse({ error: 'No business found for user' }, 403)
    }

    const businessId = profile.business_id
    const { action, areaCode, phoneNumber, friendlyName, phoneNumberId } = await req.json()

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

      return jsonResponse({ success: true, phoneNumber: inserted })
    }

    if (action === 'release') {
      if (!phoneNumberId) {
        return jsonResponse({ error: 'phoneNumberId required' }, 400)
      }

      const { data: record } = await supabase
        .from('phone_numbers')
        .select('id, twilio_sid, business_id')
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

      return jsonResponse({ success: true })
    }

    return jsonResponse({ error: 'Invalid action' }, 400)

  } catch (e) {
    return jsonResponse({ error: 'Unexpected error', detail: String(e) }, 500)
  }
})