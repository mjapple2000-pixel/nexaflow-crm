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
    const { quote_id, business_id, channel } = await req.json();

    if (!quote_id || !business_id || !channel) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const openAiKey   = Deno.env.get('OPENAI_API_KEY')!;
    const twilioSid   = Deno.env.get('TWILIO_ACCOUNT_SID')!;
    const twilioToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;
    const twilioFrom  = Deno.env.get('TWILIO_PHONE_NUMBER')!;

    const db = createClient(supabaseUrl, serviceKey);

    // Load quote + lead
    const { data: quote, error: quoteErr } = await db
      .from('quotes')
      .select('*, leads(lead_name, lead_email, lead_phone)')
      .eq('id', quote_id)
      .eq('business_id', business_id)
      .single();

    if (quoteErr || !quote) {
      return new Response(JSON.stringify({ error: 'Quote not found' }), {
        status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Load business
    const { data: business } = await db
      .from('businesses')
      .select('business_name')
      .eq('id', business_id)
      .single();

    const lead         = quote.leads as Record<string, string> | null;
    const leadName     = lead?.lead_name   ?? 'there';
    const leadEmail    = lead?.lead_email  ?? '';
    const leadPhone    = lead?.lead_phone  ?? '';
    const businessName = business?.business_name ?? 'your service provider';
    const quoteNum     = quote.quote_number ?? 'Quote';
    const total        = Number(quote.total ?? 0).toFixed(2);
    const expiresAt    = quote.expires_at
      ? new Date(quote.expires_at).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })
      : null;

    // Get or generate client portal token
    const { data: leadRow } = await db
      .from('leads')
      .select('client_access_token')
      .eq('id', quote.contact_id)
      .single();

    let portalToken = leadRow?.client_access_token as string | null;
    if (!portalToken) {
      const bytes = new Uint8Array(32);
      crypto.getRandomValues(bytes);
      portalToken = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
      await db.from('leads').update({ client_access_token: portalToken }).eq('id', quote.contact_id);
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
Never use the word "quote" as a cold noun — make it feel like a natural update from a real person.`,
            },
            {
              role: 'user',
              content: `Write an SMS to ${leadName} letting them know their estimate ${quoteNum} for $${total} from ${businessName} is ready for their review.${expiresAt ? ` It expires ${expiresAt}.` : ''} Include this link naturally at the end so they can view and approve it: ${portalUrl} Keep it warm and brief.`,
            },
          ],
        }),
      });

      const aiData = await aiRes.json();
      const smsBody = aiData.choices?.[0]?.message?.content?.trim() ??
        `Hi ${leadName}, your estimate ${quoteNum} for $${total} from ${businessName} is ready! Let us know if you have any questions.`;

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
Do not use corporate jargon. Sign off naturally with the business name.`,
            },
            {
              role: 'user',
              content: `Write an email body to ${leadName} letting them know their estimate ${quoteNum} for $${total} from ${businessName} is ready for review.${expiresAt ? ` It expires ${expiresAt}.` : ''} Include this link naturally so they can view and approve it: ${portalUrl} Keep it brief and warm. Sign off with ${businessName}.`,
            },
          ],
        }),
      });

      const aiData = await aiRes.json();
      const emailBody = aiData.choices?.[0]?.message?.content?.trim() ??
        `Hi ${leadName},\n\nYour estimate ${quoteNum} for $${total} is ready for your review.${expiresAt ? ` Please note it expires on ${expiresAt}.` : ''}\n\nFeel free to reach out with any questions!\n\n${businessName}`;

      const emailRes = await fetch(`${supabaseUrl}/functions/v1/send-email`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${serviceKey}`,
        },
        body: JSON.stringify({
          business_id: business_id,
          lead_ids:    [quote.contact_id],
          subject:     `Your estimate from ${businessName} — ${quoteNum}`,
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

    // Flip quote to sent
    const now = new Date().toISOString();
    await db.from('quotes').update({
      status:     'sent',
      sent_at:    now,
      updated_at: now,
    }).eq('id', quote_id);

    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});