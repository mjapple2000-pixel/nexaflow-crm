import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      secretKeys.nexaflow_service_role_2026_08 ?? '',
    );

    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders });

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: corsHeaders });

    const body = await req.json();
    const campaignId = body.campaign_id;
    if (!campaignId) {
      return new Response(JSON.stringify({ error: 'campaign_id required' }), { status: 400, headers: corsHeaders });
    }

    // ── Superuser bypass ── same pattern as the Stripe Connect functions and
    // preview-campaign-audience. Superuser has no profiles row by design.
    const { data: suRow } = await supabase
      .from('superusers')
      .select('user_id')
      .eq('user_id', user.id)
      .maybeSingle();
    const isSuperuser = !!suRow;

    let businessId: number | null = null;
    if (isSuperuser) {
      businessId = body?.business_id ?? null;
      if (!businessId) {
        return new Response(JSON.stringify({ error: 'business_id is required' }), { status: 400, headers: corsHeaders });
      }
    } else {
      const { data: profile } = await supabase
        .from('profiles')
        .select('business_id')
        .eq('user_id', user.id)
        .single();

      if (!profile?.business_id) {
        return new Response(JSON.stringify({ error: 'No business found' }), { status: 400, headers: corsHeaders });
      }
      businessId = profile.business_id;
    }

    // Verify campaign belongs to this business
    const { data: campaign, error: campaignErr } = await supabase
      .from('campaigns')
      .select('id, type, status, filter_config, message_body')
      .eq('id', campaignId)
      .eq('business_id', businessId)
      .single();

    if (campaignErr || !campaign) {
      return new Response(JSON.stringify({ error: 'Campaign not found' }), { status: 404, headers: corsHeaders });
    }
    if (campaign.status === 'sending' || campaign.status === 'sent') {
      return new Response(JSON.stringify({ error: 'Campaign already sent or sending' }), { status: 400, headers: corsHeaders });
    }
    if (!campaign.message_body) {
      return new Response(JSON.stringify({ error: 'Campaign has no message body' }), { status: 400, headers: corsHeaders });
    }

    // ── Channel-aware targeting ── an email campaign needs leads with a real
    // email on file, not a phone number. campaign.type is already stored at
    // creation time, so no extra param is needed from the caller here.
    const channel = campaign.type === 'email' ? 'email' : 'sms';
    const contactColumn = channel === 'email' ? 'lead_email' : 'lead_phone';

    const filterConfig = campaign.filter_config ?? {};

    // Build lead query server-side
    let query = supabase
      .from('leads')
      .select('id, lead_phone, lead_email')
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .not(contactColumn, 'is', null);

    if (filterConfig.tags && filterConfig.tags.length > 0) {
      query = query.filter('tags', 'cs', JSON.stringify(filterConfig.tags));
    }
    if (filterConfig.sources && filterConfig.sources.length > 0) {
      query = query.in('source', filterConfig.sources);
    }
    if (filterConfig.lead_statuses && filterConfig.lead_statuses.length > 0) {
      query = query.in('lead_status', filterConfig.lead_statuses);
    }

    const { data: leads, error: leadsErr } = await query;
    if (leadsErr) throw leadsErr;

    if (!leads || leads.length === 0) {
      return new Response(JSON.stringify({ error: 'No leads match this audience' }), { status: 400, headers: corsHeaders });
    }

    // Filter out DND leads via conversations table (SMS channel only — DND
    // is a texting concept; email campaigns don't check it)
    let eligible = leads;
    if (channel === 'sms') {
      const leadIds = leads.map((l: { id: number }) => l.id);
      const { data: dndConvos } = await supabase
        .from('conversations')
        .select('lead_id')
        .eq('business_id', businessId)
        .eq('dnd', true)
        .in('lead_id', leadIds);

      const dndSet = new Set((dndConvos ?? []).map((c: { lead_id: number }) => c.lead_id));
      eligible = leads.filter((l: { id: number }) => !dndSet.has(l.id));
    }

    if (eligible.length === 0) {
      return new Response(JSON.stringify({ error: 'All matched leads have DND enabled' }), { status: 400, headers: corsHeaders });
    }

    // Set campaign to sending
    await supabase
      .from('campaigns')
      .update({
        status: 'sending',
        recipient_count: eligible.length,
      })
      .eq('id', campaignId);

    // Queue one campaign_contacts row per eligible lead
    const rows = eligible.map((l: { id: number }) => ({
      campaign_id: campaignId,
      lead_id: l.id,
      business_id: businessId,
      status: 'queued',
    }));

    const { error: insertErr } = await supabase
      .from('campaign_contacts')
      .insert(rows);

    if (insertErr) throw insertErr;

    return new Response(JSON.stringify({ queued: eligible.length, channel }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (e: unknown) {
    console.error('send-campaign error:', e);
    const message = e instanceof Error ? e.message : JSON.stringify(e);
    return new Response(JSON.stringify({ error: message, raw: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});