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

    // ── Superuser bypass ── same pattern as the Stripe Connect functions.
    // The superuser account (vantagecaretech@gmail.com) has no profiles row
    // by design, so the plain profile lookup below always failed for it —
    // this function silently returned "No business found" / a 0 count
    // whenever tested as superuser, which looked like "can't find any leads."
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

    const filterConfig = body.filter_config ?? {};

    // ── Channel-aware targeting ── defaults to 'sms' so existing callers that
    // don't yet send this stay backward-compatible. Email campaigns need
    // leads with a real email on file, not a phone number.
    const channel = body.channel === 'email' ? 'email' : 'sms';
    const contactColumn = channel === 'email' ? 'lead_email' : 'lead_phone';

    let query = supabase
      .from('leads')
      .select('id', { count: 'exact', head: true })
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

    const { count, error } = await query;
    if (error) throw error;

    return new Response(JSON.stringify({ count: count ?? 0 }), {
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