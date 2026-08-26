import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')
    const serviceRoleKey = secretKeys.nexaflow_service_role_2026_08 ?? ''

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      serviceRoleKey
    )

    const { token, action_type, target_id, payload } = await req.json()

    if (!token || !action_type) {
      return new Response(JSON.stringify({ error: 'token and action_type required' }), { status: 400, headers: corsHeaders })
    }

    // Resolve lead + business from token — this is the auth for every action
    const { data: lead } = await adminClient
      .from('leads')
      .select('id, business_id')
      .eq('client_access_token', token)
      .is('deleted_at', null)
      .single()

    if (!lead) {
      return new Response(JSON.stringify({ error: 'Invalid or expired link' }), { status: 401, headers: corsHeaders })
    }

    const leadId = lead.id
    const businessId = lead.business_id

    switch (action_type) {

      case 'approve_quote': {
        if (!target_id) return new Response(JSON.stringify({ error: 'target_id required' }), { status: 400, headers: corsHeaders })

        const { data: quote } = await adminClient
          .from('quotes')
          .select('id, status')
          .eq('id', target_id)
          .eq('contact_id', leadId)
          .eq('business_id', businessId)
          .is('deleted_at', null)
          .single()

        if (!quote) return new Response(JSON.stringify({ error: 'Quote not found' }), { status: 404, headers: corsHeaders })
        if (quote.status !== 'sent') return new Response(JSON.stringify({ error: 'Quote is not in a state that can be approved' }), { status: 400, headers: corsHeaders })

        await adminClient
          .from('quotes')
          .update({ status: 'approved', approved_at: new Date().toISOString(), approved_via: 'client_portal' })
          .eq('id', target_id)

        return new Response(JSON.stringify({ success: true }), { status: 200, headers: corsHeaders })
      }

      case 'decline_quote': {
        if (!target_id) return new Response(JSON.stringify({ error: 'target_id required' }), { status: 400, headers: corsHeaders })

        const { data: quote } = await adminClient
          .from('quotes')
          .select('id, status')
          .eq('id', target_id)
          .eq('contact_id', leadId)
          .eq('business_id', businessId)
          .is('deleted_at', null)
          .single()

        if (!quote) return new Response(JSON.stringify({ error: 'Quote not found' }), { status: 404, headers: corsHeaders })
        if (!['sent', 'approved'].includes(quote.status)) return new Response(JSON.stringify({ error: 'Quote cannot be declined in its current state' }), { status: 400, headers: corsHeaders })

        await adminClient
          .from('quotes')
          .update({ status: 'declined' })
          .eq('id', target_id)

        return new Response(JSON.stringify({ success: true }), { status: 200, headers: corsHeaders })
      }

      case 'submit_service_request': {
        const description = payload?.description?.trim()
        if (!description) return new Response(JSON.stringify({ error: 'description required' }), { status: 400, headers: corsHeaders })

        const { error: insertError } = await adminClient
          .from('client_service_requests')
          .insert({
            business_id: businessId,
            lead_id: leadId,
            description,
            preferred_date: payload?.preferred_date ?? null,
            status: 'new',
          })

        if (insertError) {
          console.error('Service request insert error:', insertError)
          return new Response(JSON.stringify({ error: 'Failed to submit request' }), { status: 500, headers: corsHeaders })
        }

        return new Response(JSON.stringify({ success: true }), { status: 200, headers: corsHeaders })
      }

      case 'pay_invoice': {
        if (!target_id) return new Response(JSON.stringify({ error: 'target_id required' }), { status: 400, headers: corsHeaders })

        const { data: invoice } = await adminClient
          .from('invoices')
          .select('id, status, amount_due, invoice_number, contact_id, leads(lead_email)')
          .eq('id', target_id)
          .eq('contact_id', leadId)
          .eq('business_id', businessId)
          .is('deleted_at', null)
          .single()

        if (!invoice) return new Response(JSON.stringify({ error: 'Invoice not found' }), { status: 404, headers: corsHeaders })
        if (!['approved', 'sent'].includes(invoice.status)) return new Response(JSON.stringify({ error: 'Invoice is not payable' }), { status: 400, headers: corsHeaders })

        const supabaseUrl = Deno.env.get('SUPABASE_URL')!

        const payRes = await fetch(`${supabaseUrl}/functions/v1/create-invoice-payment`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${serviceRoleKey}`,
          },
          body: JSON.stringify({
            invoice_id: target_id,
          }),
        })

        const payData = await payRes.json()
        if (!payRes.ok || !payData.url) {
          return new Response(JSON.stringify({ error: payData.error ?? 'Failed to create payment session' }), { status: 500, headers: corsHeaders })
        }

        return new Response(JSON.stringify({ success: true, url: payData.url }), { status: 200, headers: corsHeaders })
      }

      // JG-12: pays ONE milestone rather than the whole invoice.
      // target_id here is the milestone id (invoice_milestones.id), not
      // the invoice id — the parent invoice_id comes from payload so we
      // can verify the milestone actually belongs to this lead's invoice
      // before ever calling create-invoice-payment.
      case 'pay_milestone': {
        if (!target_id) return new Response(JSON.stringify({ error: 'target_id required' }), { status: 400, headers: corsHeaders })
        const invoiceId = payload?.invoice_id
        if (!invoiceId) return new Response(JSON.stringify({ error: 'payload.invoice_id required' }), { status: 400, headers: corsHeaders })

        // Verify the invoice belongs to this lead/business first
        const { data: invoice } = await adminClient
          .from('invoices')
          .select('id')
          .eq('id', invoiceId)
          .eq('contact_id', leadId)
          .eq('business_id', businessId)
          .is('deleted_at', null)
          .single()

        if (!invoice) return new Response(JSON.stringify({ error: 'Invoice not found' }), { status: 404, headers: corsHeaders })

        // Verify the milestone belongs to that invoice and is payable
        const { data: milestone } = await adminClient
          .from('invoice_milestones')
          .select('id, status')
          .eq('id', target_id)
          .eq('invoice_id', invoiceId)
          .is('deleted_at', null)
          .single()

        if (!milestone) return new Response(JSON.stringify({ error: 'Milestone not found' }), { status: 404, headers: corsHeaders })
        if (!['ready_to_bill', 'sent'].includes(milestone.status)) {
          return new Response(JSON.stringify({ error: 'This milestone is not payable yet' }), { status: 400, headers: corsHeaders })
        }

        const supabaseUrl = Deno.env.get('SUPABASE_URL')!

        const payRes = await fetch(`${supabaseUrl}/functions/v1/create-invoice-payment`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${serviceRoleKey}`,
          },
          body: JSON.stringify({
            invoice_id: invoiceId,
            milestone_id: target_id,
          }),
        })

        const payData = await payRes.json()
        if (!payRes.ok || !payData.url) {
          return new Response(JSON.stringify({ error: payData.error ?? 'Failed to create payment session' }), { status: 500, headers: corsHeaders })
        }

        return new Response(JSON.stringify({ success: true, url: payData.url }), { status: 200, headers: corsHeaders })
      }

      default:
        return new Response(JSON.stringify({ error: `Unknown action_type: ${action_type}` }), { status: 400, headers: corsHeaders })
    }

  } catch (err) {
    console.error('client-portal-action error:', err)
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500, headers: corsHeaders })
  }
})