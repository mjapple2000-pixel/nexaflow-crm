import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }

  try {
    const { milestone_id, invoice_id, business_id, channel } = await req.json();

    if (!milestone_id || !invoice_id || !business_id || !channel) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const secretKeys  = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const serviceKey  = secretKeys.nexaflow_service_role_2026_08 ?? '';
    const openAiKey   = Deno.env.get('OPENAI_API_KEY')!;
    const twilioSid   = Deno.env.get('TWILIO_ACCOUNT_SID')!;
    const twilioToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;
    const twilioFrom  = Deno.env.get('TWILIO_PHONE_NUMBER')!;

    const db = createClient(supabaseUrl, serviceKey);

    // Load milestone, scoped to the invoice + business passed in
    const { data: milestone, error: msErr } = await db
      .from('invoice_milestones')
      .select('id, label, status, amount_due, invoice_id')
      .eq('id', milestone_id)
      .eq('invoice_id', invoice_id)
      .is('deleted_at', null)
      .single();

    if (msErr || !milestone) {
      return new Response(JSON.stringify({ error: 'Milestone not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (milestone.status !== 'ready_to_bill') {
      return new Response(JSON.stringify({ error: 'Milestone is not ready to bill' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Load invoice + lead
    const { data: invoice, error: invErr } = await db
      .from('invoices')
      .select('*, leads(lead_name, lead_email, lead_phone)')
      .eq('id', invoice_id)
      .eq('business_id', business_id)
      .single();

    if (invErr || !invoice) {
      return new Response(JSON.stringify({ error: 'Invoice not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Load business
    const { data: business } = await db
      .from('businesses')
      .select('business_name, business_phone')
      .eq('id', business_id)
      .single();

    const lead          = invoice.leads as Record<string, string> | null;
    const leadName      = lead?.lead_name  ?? 'there';
    const leadEmail     = lead?.lead_email ?? '';
    const leadPhone     = lead?.lead_phone ?? '';
    const businessName  = business?.business_name ?? 'your service provider';
    const invoiceNum    = invoice.invoice_number ?? 'Invoice';
    const milestoneLabel = milestone.label ?? 'This stage';
    const amountDue     = Number(milestone.amount_due ?? 0).toFixed(2);

    // Get or generate client portal token — same token/link the whole invoice uses
    const { data: leadRow } = await db
      .from('leads')
      .select('client_access_token')
      .eq('id', invoice.contact_id)
      .single();

    let portalToken = leadRow?.client_access_token as string | null;
    if (!portalToken) {
      const bytes = new Uint8Array(32);
      crypto.getRandomValues(bytes);
      portalToken = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
      await db.from('leads').update({ client_access_token: portalToken }).eq('id', invoice.contact_id);
    }
    const portalUrl = `https://nexaflow-crm.web.app/client/${portalToken}`;

    if (channel === 'sms') {
      if (!leadPhone) {
        return new Response(JSON.stringify({ error: 'Customer has no phone number on file.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const aiRes = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${openAiKey}` },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          max_tokens: 120,
          messages: [
            {
              role: 'system',
              content: `You write short, warm, professional SMS messages on behalf of home service businesses.
Write exactly one SMS message. No subject line, no quotes, no extra commentary — just the message text.
Keep it under 160 characters. Sound human and friendly, not robotic or formal.
This is billing for ONE STAGE of a multi-stage job, not the full project — make that clear but keep it brief.`,
            },
            {
              role: 'user',
              content: `Write an SMS to ${leadName} letting them know the "${milestoneLabel}" stage of their project (invoice ${invoiceNum}) is ready to bill, $${amountDue}, from ${businessName}. Include this link naturally so they can view and pay it: ${portalUrl} Keep it brief and warm. Sign off with ${businessName}.`,
            },
          ],
        }),
      });

      const aiData = await aiRes.json();
      const smsBody = aiData.choices?.[0]?.message?.content?.trim() ??
        `Hi ${leadName}, the "${milestoneLabel}" stage of invoice ${invoiceNum} ($${amountDue}) from ${businessName} is ready to bill. ${portalUrl}`;

      const twilioRes = await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${twilioSid}/Messages.json`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Authorization': `Basic ${btoa(`${twilioSid}:${twilioToken}`)}`,
          },
          body: new URLSearchParams({
            From: twilioFrom,
            To:   leadPhone,
            Body: smsBody,
          }),
        }
      );

      if (!twilioRes.ok) {
        const twilioErr = await twilioRes.text();
        return new Response(JSON.stringify({ error: `Twilio error: ${twilioErr}` }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

    } else if (channel === 'email') {
      if (!leadEmail) {
        return new Response(JSON.stringify({ error: 'Customer has no email address on file.' }), {
          status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      const aiRes = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${openAiKey}` },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          max_tokens: 220,
          messages: [
            {
              role: 'system',
              content: `You write short, warm, professional emails on behalf of home service businesses.
Write exactly one email body (no subject line, no "Subject:", no extra commentary).
Sound like a real person from a small local business — friendly, clear, and genuine.
This is billing for ONE STAGE of a multi-stage job, not the full project — make that clear so the customer
understands more billing may follow for later stages. Do not use corporate jargon. Sign off naturally with the business name.`,
            },
            {
              role: 'user',
              content: `Write an email body to ${leadName} letting them know the "${milestoneLabel}" stage of their project (invoice ${invoiceNum}) is ready to bill, $${amountDue}, from ${businessName}. Keep it brief and warm. Sign off with ${businessName}.`,
            },
          ],
        }),
      });

      const aiData = await aiRes.json();
      const emailBody = aiData.choices?.[0]?.message?.content?.trim() ??
        `Hi ${leadName},\n\nThe "${milestoneLabel}" stage of invoice ${invoiceNum} ($${amountDue}) is ready to bill.\n\nThank you,\n${businessName}`;

      const emailRes = await fetch(`${supabaseUrl}/functions/v1/send-email`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${serviceKey}`,
        },
        body: JSON.stringify({
          business_id: business_id,
          lead_ids:    [invoice.contact_id],
          subject:     `${milestoneLabel} — ${businessName} (${invoiceNum})`,
          body:        emailBody,
        }),
      });

      if (!emailRes.ok) {
        const emailErr = await emailRes.text();
        return new Response(JSON.stringify({ error: `Email error: ${emailErr}` }), {
          status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

    } else {
      return new Response(JSON.stringify({ error: 'Invalid channel. Use sms or email.' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Flip milestone to sent — never touches invoice status/amount_paid, those are
    // owned exclusively by stripe-connect-webhook on actual payment
    const now = new Date().toISOString();
    await db.from('invoice_milestones').update({
      status:      'sent',
      invoiced_at: now,
      updated_at:  now,
    }).eq('id', milestone_id);

    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});