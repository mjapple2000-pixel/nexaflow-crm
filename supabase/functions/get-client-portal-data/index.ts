import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const url = new URL(req.url)
    const token = url.searchParams.get('token')

    if (!token) return new Response(JSON.stringify({ error: 'Token required' }), { status: 400, headers: corsHeaders })

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Resolve lead from token
    const { data: lead } = await adminClient
      .from('leads')
      .select('id, business_id, lead_name, lead_email, lead_phone')
      .eq('client_access_token', token)
      .is('deleted_at', null)
      .single()

    if (!lead) {
      return new Response(JSON.stringify({ error: 'Invalid or expired link' }), { status: 404, headers: corsHeaders })
    }

    const leadId = lead.id
    const businessId = lead.business_id

    // Business info + Stripe status
    const { data: business } = await adminClient
      .from('businesses')
      .select('business_name, stripe_connect_ready')
      .eq('id', businessId)
      .single()

    // Upcoming appointments
    const { data: appointments } = await adminClient
      .from('appointments')
      .select('id, scheduled_at, appointment_type, status, notes')
      .eq('lead_id', leadId)
      .eq('business_id', businessId)
      .gt('scheduled_at', new Date().toISOString())
      .is('deleted_at', null)
      .order('scheduled_at', { ascending: true })

    // Quotes with line items
    const { data: quotes } = await adminClient
      .from('quotes')
      .select('id, quote_number, job_title, total, status, created_at, expires_at')
      .eq('contact_id', leadId)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .order('created_at', { ascending: false })

    // Quote line items
    const quoteIds = (quotes ?? []).map((q: any) => q.id)
    let quoteLineItems: any[] = []
    if (quoteIds.length > 0) {
      const { data: qli } = await adminClient
        .from('line_items')
        .select('parent_id, description, quantity, unit_price, total, discount_type, discount_value, sort_order')
        .eq('parent_type', 'quote')
        .in('parent_id', quoteIds)
        .is('deleted_at', null)
        .order('sort_order')
      quoteLineItems = qli ?? []
    }

    // Attach line items to each quote
    const quotesWithItems = (quotes ?? []).map((q: any) => ({
      ...q,
      line_items: quoteLineItems.filter((li: any) => li.parent_id === q.id),
    }))

    // Invoices with line items
    const { data: invoices } = await adminClient
      .from('invoices')
      .select('id, invoice_number, job_title, amount_due, subtotal, tax_rate, tax_amount, status, created_at, due_date, paid_at, notes')
      .eq('contact_id', leadId)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .order('created_at', { ascending: false })

    // Invoice line items
    const invoiceIds = (invoices ?? []).map((i: any) => i.id)
    let invoiceLineItems: any[] = []
    if (invoiceIds.length > 0) {
      const { data: ili } = await adminClient
        .from('line_items')
        .select('parent_id, description, quantity, unit_price, total, discount_type, discount_value, sort_order')
        .eq('parent_type', 'invoice')
        .in('parent_id', invoiceIds)
        .is('deleted_at', null)
        .order('sort_order')
      invoiceLineItems = ili ?? []
    }

    // Attach line items to each invoice
    const invoicesWithItems = (invoices ?? []).map((i: any) => ({
      ...i,
      line_items: invoiceLineItems.filter((li: any) => li.parent_id === i.id),
    }))

    // Service requests
    const { data: serviceRequests } = await adminClient
      .from('client_service_requests')
      .select('id, description, preferred_date, status, created_at')
      .eq('lead_id', leadId)
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .order('created_at', { ascending: false })

    return new Response(
      JSON.stringify({
        lead: {
          first_name: (lead.lead_name as string)?.split(' ')[0] ?? 'there',
          full_name: lead.lead_name,
          email: lead.lead_email,
        },
        business: {
          name: business?.business_name ?? '',
          logo_url: null,
          stripe_connect_ready: business?.stripe_connect_ready === true,
        },
        appointments: appointments ?? [],
        quotes: quotesWithItems,
        invoices: invoicesWithItems,
        service_requests: serviceRequests ?? [],
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('get-client-portal-data error:', err)
    return new Response(JSON.stringify({ error: 'Internal server error' }), { status: 500, headers: corsHeaders })
  }
})