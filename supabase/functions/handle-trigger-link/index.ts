import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const url = new URL(req.url)
    // URL pattern: /handle-trigger-link/TOKEN/LEAD_ID
    const parts = url.pathname.split('/').filter(Boolean)
    // parts: ['handle-trigger-link', 'TOKEN', 'LEAD_ID']
    const token = parts[1]
    const leadId = parts[2] ? parseInt(parts[2]) : null

    if (!token) {
      return new Response('Invalid link', { status: 400 })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    // 1. Look up the trigger link by token
    const { data: triggerLink, error: linkError } = await supabase
      .from('trigger_links')
      .select('id, business_id, name, token, redirect_url, automation_id, automations(id, name, actions)')
      .eq('token', token)
      .single()

    if (linkError || !triggerLink) {
      return new Response('Link not found', { status: 404 })
    }

    // 2. Log the click
    const ipAddress = req.headers.get('x-forwarded-for') ?? req.headers.get('cf-connecting-ip') ?? null
    const contactPhone = leadId ? null : url.searchParams.get('phone')

    await supabase.from('trigger_link_clicks').insert({
      trigger_link_id: triggerLink.id,
      lead_id: leadId ?? null,
      contact_phone: contactPhone,
      ip_address: ipAddress,
    })

    // 3. Increment click count
    await supabase
      .from('trigger_links')
      .update({ click_count: (triggerLink as any).click_count + 1 })
      .eq('id', triggerLink.id)

    // 4. Fire automation actions if linked
    if (triggerLink.automation_id && leadId) {
      const automation = (triggerLink as any).automations
      const actions: any[] = automation?.actions ?? []

      for (const action of actions) {
        await _executeAction(supabase, action, leadId, triggerLink.business_id)
      }
    }

    // 5. Redirect contact to destination URL
    return new Response(null, {
      status: 302,
      headers: {
        ...corsHeaders,
        'Location': triggerLink.redirect_url,
      },
    })

  } catch (err) {
    console.error('handle-trigger-link error:', err)
    return new Response('Internal error', { status: 500 })
  }
})

// ── Action executor ───────────────────────────────────────────────────────────
// Mirrors the automations engine — extend action types here as you add more
async function _executeAction(
  supabase: any,
  action: any,
  leadId: number,
  businessId: number,
) {
  const type: string = action.type ?? ''

  switch (type) {

    // Add a tag to the lead
    case 'add_tag': {
      const tag: string = action.tag ?? ''
      if (!tag) break
      const { data: lead } = await supabase
        .from('leads')
        .select('tags')
        .eq('id', leadId)
        .single()
      const currentTags: string[] = lead?.tags ?? []
      if (!currentTags.includes(tag)) {
        await supabase
          .from('leads')
          .update({ tags: [...currentTags, tag] })
          .eq('id', leadId)
      }
      break
    }

    // Remove a tag from the lead
    case 'remove_tag': {
      const tag: string = action.tag ?? ''
      if (!tag) break
      const { data: lead } = await supabase
        .from('leads')
        .select('tags')
        .eq('id', leadId)
        .single()
      const currentTags: string[] = lead?.tags ?? []
      await supabase
        .from('leads')
        .update({ tags: currentTags.filter((t: string) => t !== tag) })
        .eq('id', leadId)
      break
    }

    // Update lead status
    case 'update_status': {
      const status: string = action.status ?? ''
      if (!status) break
      await supabase
        .from('leads')
        .update({ lead_status: status })
        .eq('id', leadId)
      break
    }

    // Update lead field (generic)
    case 'update_field': {
      const field: string = action.field ?? ''
      const value = action.value
      if (!field) break
      await supabase
        .from('leads')
        .update({ [field]: value })
        .eq('id', leadId)
      break
    }

    // Send SMS via Twilio (fires outbound_messages webhook or direct insert)
    case 'send_sms': {
      const messageBody: string = action.message ?? ''
      if (!messageBody) break

      // Look up lead phone
      const { data: lead } = await supabase
        .from('leads')
        .select('lead_phone')
        .eq('id', leadId)
        .single()
      if (!lead?.lead_phone) break

      // Find or create conversation
      const { data: conv } = await supabase
        .from('conversations')
        .select('id')
        .eq('lead_phone', lead.lead_phone)
        .eq('business_id', businessId)
        .single()

      const convId = conv?.id ?? null

      if (convId) {
        // Insert outbound message — Twilio realtime function will pick this up
        await supabase.from('messages').insert({
          conversation_id: convId,
          business_id: businessId,
          body: messageBody,
          direction: 'outbound',
          channel: 'sms',
          status: 'sending',
          sender_name: 'Automation',
          sent_via_twiml: false, // let outbound webhook send it
        })
      }
      break
    }

    // Enroll in another automation
    case 'enroll_automation': {
      const targetAutomationId: number = action.automation_id
      if (!targetAutomationId) break
      await supabase.from('automation_enrollments').insert({
        business_id: businessId,
        automation_id: targetAutomationId,
        lead_id: leadId,
        status: 'active',
        enrolled_at: new Date().toISOString(),
      })
      break
    }

    // Log to automation_logs for audit trail
    case 'log': {
      await supabase.from('automation_logs').insert({
        business_id: businessId,
        lead_id: leadId,
        action_type: 'trigger_link_click',
        details: action.message ?? 'Trigger link clicked',
      })
      break
    }

    default:
      console.log(`handle-trigger-link: unknown action type "${type}" — skipping`)
      break
  }
}