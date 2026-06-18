import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BATCH_SIZE = 10;

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const twilioAccountSid = Deno.env.get('TWILIO_ACCOUNT_SID')!;
    const twilioAuthToken = Deno.env.get('TWILIO_AUTH_TOKEN')!;
    const twilioFrom = Deno.env.get('TWILIO_PHONE_NUMBER')!;

    // Fetch a batch of queued rows
    const { data: queuedRows, error: fetchErr } = await supabase
      .from('campaign_contacts')
      .select('id, campaign_id, lead_id, business_id')
      .eq('status', 'queued')
      .is('deleted_at', null)
      .order('created_at', { ascending: true })
      .limit(BATCH_SIZE);

    if (fetchErr) throw fetchErr;
    if (!queuedRows || queuedRows.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Fetch message bodies for affected campaigns
    const campaignIds = [...new Set(queuedRows.map((r: { campaign_id: number }) => r.campaign_id))];
    const { data: campaigns, error: campErr } = await supabase
      .from('campaigns')
      .select('id, message_body')
      .in('id', campaignIds);

    if (campErr) throw campErr;

    const campaignMap: Record<number, string> = {};
    for (const c of campaigns ?? []) {
      campaignMap[c.id] = c.message_body;
    }

    // Fetch lead phone numbers
    const leadIds = queuedRows.map((r: { lead_id: number }) => r.lead_id);
    const { data: leadRows, error: leadErr } = await supabase
      .from('leads')
      .select('id, lead_phone')
      .in('id', leadIds);

    if (leadErr) throw leadErr;

    const phoneMap: Record<number, string> = {};
    for (const l of leadRows ?? []) {
      if (l.lead_phone) phoneMap[l.id] = l.lead_phone;
    }

    // Send each row
    let sentCount = 0;
    const affectedCampaignIds = new Set<number>();

    for (const row of queuedRows) {
      const toPhone = phoneMap[row.lead_id];
      const messageBody = campaignMap[row.campaign_id];

      if (!toPhone || !messageBody) {
        await supabase
          .from('campaign_contacts')
          .update({
            status: 'failed',
            error_message: !toPhone ? 'No phone number on lead' : 'No message body on campaign',
            sent_at: new Date().toISOString(),
          })
          .eq('id', row.id);
        affectedCampaignIds.add(row.campaign_id);
        continue;
      }

      try {
        const twilioRes = await fetch(
          `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`,
          {
            method: 'POST',
            headers: {
              'Authorization': 'Basic ' + btoa(`${twilioAccountSid}:${twilioAuthToken}`),
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
              From: twilioFrom,
              To: toPhone,
              Body: messageBody,
            }),
          },
        );

        const twilioData = await twilioRes.json();

        if (twilioRes.ok && twilioData.sid) {
          await supabase
            .from('campaign_contacts')
            .update({
              status: 'sent',
              sent_at: new Date().toISOString(),
            })
            .eq('id', row.id);
          sentCount++;
        } else {
          await supabase
            .from('campaign_contacts')
            .update({
              status: 'failed',
              error_message: twilioData.message ?? 'Twilio error',
              sent_at: new Date().toISOString(),
            })
            .eq('id', row.id);
        }
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error';
        await supabase
          .from('campaign_contacts')
          .update({
            status: 'failed',
            error_message: message,
            sent_at: new Date().toISOString(),
          })
          .eq('id', row.id);
      }

      affectedCampaignIds.add(row.campaign_id);
    }

    // Check if any affected campaigns are fully complete
    for (const campaignId of affectedCampaignIds) {
      const { count: pendingCount } = await supabase
        .from('campaign_contacts')
        .select('id', { count: 'exact', head: true })
        .eq('campaign_id', campaignId)
        .eq('status', 'queued')
        .is('deleted_at', null);

      if (pendingCount === 0) {
        const { count: sentTotal } = await supabase
          .from('campaign_contacts')
          .select('id', { count: 'exact', head: true })
          .eq('campaign_id', campaignId)
          .eq('status', 'sent')
          .is('deleted_at', null);

        await supabase
          .from('campaigns')
          .update({
            status: 'sent',
            sent_at: new Date().toISOString(),
            sent_count: sentTotal ?? 0,
          })
          .eq('id', campaignId);
      }
    }

    return new Response(JSON.stringify({ processed: queuedRows.length, sent: sentCount }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : 'Unknown error';
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});