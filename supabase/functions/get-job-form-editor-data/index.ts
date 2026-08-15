import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// job-form-media is private — Flutter can't create signed URLs for it
// directly (no client-side read policy, same reason the Fill Screen gets
// its photo URLs from an edge function rather than the client SDK). This
// is that same pattern, for reopening Adjust Field Positions on an
// already-saved AI-recreated form.
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    if (!token) return jsonResponse({ error: 'Missing auth token' }, 401);

    const { data: userData } = await supabase.auth.getUser(token);
    if (!userData?.user) return jsonResponse({ error: 'Invalid session' }, 401);

    const { data: profile } = await supabase
      .from('profiles')
      .select('business_id')
      .eq('user_id', userData.user.id)
      .maybeSingle();

    const { job_form_id } = await req.json();
    if (!job_form_id) return jsonResponse({ error: 'job_form_id is required' }, 400);

    const { data: jobForm, error } = await supabase
      .from('job_forms')
      .select('id, business_id, fields, sections, background_pages, recreation_mode')
      .eq('id', job_form_id)
      .maybeSingle();

    if (error || !jobForm) return jsonResponse({ error: 'Job form not found' }, 404);

    if (profile?.business_id && profile.business_id !== jobForm.business_id) {
      return jsonResponse({ error: 'Not authorized for this form' }, 403);
    }

    const backgroundPages: string[] = jobForm.background_pages ?? [];
    const pageUrls: string[] = [];
    for (const path of backgroundPages) {
      const { data: signed } = await supabase.storage.from('job-form-media').createSignedUrl(path, 3600);
      pageUrls.push(signed?.signedUrl ?? '');
    }

    return jsonResponse({
      fields: jobForm.fields ?? [],
      sections: jobForm.sections ?? [],
      background_pages: backgroundPages,
      page_urls: pageUrls,
      business_id: jobForm.business_id,
    });
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});