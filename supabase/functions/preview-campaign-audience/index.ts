import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
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

    const { data: profile } = await supabase
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .single();

    if (!profile?.business_id) {
      return new Response(JSON.stringify({ error: 'No business found' }), { status: 400, headers: corsHeaders });
    }
    const businessId = profile.business_id;

    const body = await req.json();
    const filterConfig = body.filter_config ?? {};

    let query = supabase
      .from('leads')
      .select('id', { count: 'exact', head: true })
      .eq('business_id', businessId)
      .is('deleted_at', null)
      .not('lead_phone', 'is', null);

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