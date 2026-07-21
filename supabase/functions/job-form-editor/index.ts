import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

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

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// One function, two actions — matches the existing submit-job-form-action
// pattern rather than a new function per operation. Both actions exist
// because job-form-media is private/service-role-write-only by design:
// "load" hands back signed URLs for reading (Flutter can't sign a private
// bucket URL itself), "erase" is the one sanctioned write path for saving
// a pixel edit back (Flutter can't write to this bucket directly either).
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

    const body = await req.json();
    const { action, job_form_id } = body;

    if (!action || !job_form_id) {
      return jsonResponse({ error: 'action and job_form_id are required' }, 400);
    }

    const { data: jobForm, error: formErr } = await supabase
      .from('job_forms')
      .select('id, business_id, fields, sections, background_pages, recreation_mode')
      .eq('id', job_form_id)
      .maybeSingle();

    if (formErr || !jobForm) return jsonResponse({ error: 'Job form not found' }, 404);

    // Superuser rows have no profiles entry (business_id null) — bypass
    // ownership check for them, same pattern used elsewhere in the app.
    if (profile?.business_id && profile.business_id !== jobForm.business_id) {
      return jsonResponse({ error: 'Not authorized for this form' }, 403);
    }

    if (action === 'load') {
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
    }

    if (action === 'erase') {
      const { path, file_base64 } = body;
      if (!path || !file_base64) {
        return jsonResponse({ error: 'path and file_base64 are required for erase' }, 400);
      }
      const backgroundPages: string[] = jobForm.background_pages ?? [];
      if (!backgroundPages.includes(String(path))) {
        return jsonResponse({ error: 'Path does not belong to this form' }, 400);
      }
      const bytes = base64ToBytes(String(file_base64));
      const { error: uploadError } = await supabase.storage
        .from('job-form-media')
        .upload(String(path), bytes, { contentType: 'image/png', upsert: true });
      if (uploadError) return jsonResponse({ error: 'Upload failed: ' + uploadError.message }, 500);
      return jsonResponse({ success: true });
    }

    if (action === 'save_fields') {
      const { fields, sections } = body;
      const { error: updateError } = await supabase
        .from('job_forms')
        .update({ fields: fields ?? [], sections: sections ?? [] })
        .eq('id', job_form_id);
      if (updateError) return jsonResponse({ error: 'Save failed: ' + updateError.message }, 500);
      return jsonResponse({ success: true });
    }

    return jsonResponse({ error: `Unknown action: ${action}` }, 400);
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});