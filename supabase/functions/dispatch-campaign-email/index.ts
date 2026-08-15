import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const BATCH_SIZE = 10;
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? '';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // Shared-secret check — same pattern as dispatch-campaign-sms and the
  // other pg_cron-triggered functions.
  const providedSecret = req.headers.get('x-cron-secret') ?? '';
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      secretKeys.nexaflow_service_role_2026_08 ?? '',
    );

    const mailgunApiKey = Deno.env.get('MAILGUN_API_KEY')!;
    const mailgunDomain = Deno.env.get('MAILGUN_DOMAIN')!;

    // Fetch a batch of queued rows belonging to EMAIL campaigns only —
    // dispatch-campaign-sms already claims the SMS ones. Join is done as two
    // steps (no embedded relation) to match the style already used elsewhere
    // in this function family.
    const { data: emailCampaigns, error: campErr } = await supabase
      .from('campaigns')
      .select('id, subject, message_body')
      .eq('type', 'email');

    if (campErr) throw campErr;

    const emailCampaignIds = (emailCampaigns ?? []).map((c: { id: number }) => c.id);
    if (emailCampaignIds.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const { data: queuedRows, error: fetchErr } = await supabase
      .from('campaign_contacts')
      .select('id, campaign_id, lead_id, business_id')
      .eq('status', 'queued')
      .in('campaign_id', emailCampaignIds)
      .is('deleted_at', null)
      .order('created_at', { ascending: true })
      .limit(BATCH_SIZE);

    if (fetchErr) throw fetchErr;
    if (!queuedRows || queuedRows.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const campaignMap: Record<number, { subject: string; message_body: string }> = {};
    for (const c of emailCampaigns ?? []) {
      campaignMap[c.id] = { subject: c.subject ?? '', message_body: c.message_body ?? '' };
    }

    // Fetch lead names/emails
    const leadIds = queuedRows.map((r: { lead_id: number }) => r.lead_id);
    const { data: leadRows, error: leadErr } = await supabase
      .from('leads')
      .select('id, lead_name, lead_email')
      .in('id', leadIds);

    if (leadErr) throw leadErr;

    const leadMap: Record<number, { lead_name: string; lead_email: string }> = {};
    for (const l of leadRows ?? []) {
      if (l.lead_email) leadMap[l.id] = { lead_name: l.lead_name ?? 'there', lead_email: l.lead_email };
    }

    let sentCount = 0;
    const affectedCampaignIds = new Set<number>();

    for (const row of queuedRows) {
      const lead = leadMap[row.lead_id];
      const campaign = campaignMap[row.campaign_id];

      if (!lead || !campaign?.message_body) {
        await supabase
          .from('campaign_contacts')
          .update({
            status: 'failed',
            error_message: !lead ? 'No email address on lead' : 'No message body on campaign',
            sent_at: new Date().toISOString(),
          })
          .eq('id', row.id);
        affectedCampaignIds.add(row.campaign_id);
        continue;
      }

      try {
        const personalizedBody = campaign.message_body.replace(/\{\{name\}\}/gi, lead.lead_name);
        const personalizedSubject = (campaign.subject || 'A message for you').replace(/\{\{name\}\}/gi, lead.lead_name);

        const formData = new FormData();
        formData.append('from', 'Vantagecaretech <vantagecaretech@gmail.com>');
        formData.append('to', `${lead.lead_name} <${lead.lead_email}>`);
        formData.append('subject', personalizedSubject);
        formData.append('text', personalizedBody);
        formData.append('html', `<div style="font-family:sans-serif;font-size:14px;line-height:1.6;color:#222">${personalizedBody.replace(/\n/g, '<br>')}</div>`);

        const mgRes = await fetch(
          `https://api.mailgun.net/v3/${mailgunDomain}/messages`,
          {
            method: 'POST',
            headers: { 'Authorization': 'Basic ' + btoa(`api:${mailgunApiKey}`) },
            body: formData,
          },
        );

        if (mgRes.ok) {
          await supabase
            .from('campaign_contacts')
            .update({ status: 'sent', sent_at: new Date().toISOString() })
            .eq('id', row.id);
          sentCount++;
        } else {
          const mgErr = await mgRes.text();
          await supabase
            .from('campaign_contacts')
            .update({
              status: 'failed',
              error_message: mgErr,
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

    // Check if any affected campaigns are fully complete — same pattern as dispatch-campaign-sms
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