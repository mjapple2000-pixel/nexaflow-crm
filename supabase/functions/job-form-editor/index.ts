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
    const { action, job_form_id, business_id: businessIdParam } = body;

    if (!action) {
      return jsonResponse({ error: 'action is required' }, 400);
    }

    // 'use_template' looks up a form_template_id, not a job_form_id the
    // caller owns — it has its own auth handling further below. Every
    // other action operates on a specific job_forms row the caller must
    // own, so that lookup + ownership check stays shared here.
    let jobForm: any = null;
    if (action !== 'use_template' && action !== 'update_template_tags' && action !== 'create_tag') {
      if (!job_form_id) {
        return jsonResponse({ error: 'job_form_id is required for this action' }, 400);
      }
      const { data: fetchedForm, error: formErr } = await supabase
        .from('job_forms')
        .select('id, business_id, fields, sections, background_pages, recreation_mode, signature_box, requires_signature, photo_attachment_markers, name, form_type, page_number_start, page_number_total_override, is_blank_template')
        .eq('id', job_form_id)
        .maybeSingle();

      if (formErr || !fetchedForm) return jsonResponse({ error: 'Job form not found' }, 404);

      // Superuser rows have no profiles entry (business_id null) — bypass
      // ownership check for them, same pattern used elsewhere in the app.
      if (profile?.business_id && profile.business_id !== fetchedForm.business_id) {
        return jsonResponse({ error: 'Not authorized for this form' }, 403);
      }
      jobForm = fetchedForm;
    }

    // Used only by actions with no jobForm.business_id to fall back on
    // (i.e. use_template). Superuser sessions have no profiles row, so
    // accept an explicit business_id param as a fallback — same pattern
    // already used in extract-job-form-ai.
    const resolvedBusinessId = profile?.business_id ?? businessIdParam ?? null;

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
        signature_box: jobForm.signature_box ?? null,
        requires_signature: jobForm.requires_signature ?? false,
        photo_attachment_markers: jobForm.photo_attachment_markers ?? [],
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

    // Publishes a business's own job_forms row into the shared library —
    // this is the ONLY write path into form_templates/form_template_tags,
    // since RLS deliberately gives authenticated users read-only access to
    // those tables (see schema notes). Ownership of job_form_id was already
    // verified above via the shared jobForm lookup.
    if (action === 'share_template') {
      const { title, description, tag_ids } = body;
      if (!title || typeof title !== 'string' || !title.trim()) {
        return jsonResponse({ error: 'title is required' }, 400);
      }
      const { data: template, error: templateErr } = await supabase
        .from('form_templates')
        .insert({
          business_id: jobForm.business_id,
          title: title.trim(),
          description: description ?? null,
          source_job_form_id: job_form_id,
          // Gating happens at the Library screen level (same Growth/Pro
          // check as AI Form Recreation itself) — min_tier exists for a
          // future per-template gate, not used by any gate yet.
          min_tier: 'starter',
        })
        .select('id')
        .single();
      if (templateErr || !template) {
        return jsonResponse({ error: 'Could not create template: ' + templateErr?.message }, 500);
      }

      const tagIds: number[] = Array.isArray(tag_ids) ? tag_ids : [];
      if (tagIds.length > 0) {
        const tagRows = tagIds.map((tagId) => ({ form_template_id: template.id, tag_id: tagId }));
        const { error: tagErr } = await supabase.from('form_template_tags').insert(tagRows);
        if (tagErr) return jsonResponse({ error: 'Template created but tags failed: ' + tagErr.message }, 500);
      }

      return jsonResponse({ success: true, form_template_id: template.id });
    }

    // Copies a shared template into the REQUESTING business's own
    // job_forms — a new, independent row, not a reference. Background page
    // images live in a private bucket (job-form-media), so they must be
    // physically copied to a path scoped to the new business; storage
    // writes to that bucket only ever happen via service-role, which is
    // exactly why this has to be an edge function action rather than a
    // direct Flutter insert.
    if (action === 'use_template') {
      const { form_template_id } = body;
      if (!form_template_id) return jsonResponse({ error: 'form_template_id is required' }, 400);
      if (!resolvedBusinessId) return jsonResponse({ error: 'Could not resolve requesting business' }, 401);

      const { data: template, error: templateErr } = await supabase
        .from('form_templates')
        .select('id, source_job_form_id, title')
        .eq('id', form_template_id)
        .is('deleted_at', null)
        .maybeSingle();
      if (templateErr || !template) return jsonResponse({ error: 'Template not found' }, 404);

      const { data: sourceForm, error: sourceErr } = await supabase
        .from('job_forms')
        .select('fields, sections, signature_box, requires_signature, form_type, recreation_mode, background_pages, page_number_start, page_number_total_override')
        .eq('id', template.source_job_form_id)
        .maybeSingle();
      if (sourceErr || !sourceForm) return jsonResponse({ error: 'Source form not found' }, 404);

      // Create the new row FIRST (empty background_pages) so there's a
      // real id to build destination storage paths from — pages are
      // copied after, then the row is updated with the new paths. Same
      // two-step shape already used when a draft is first confirmed via
      // confirm-job-form-recreation.
      const { data: newForm, error: insertErr } = await supabase
        .from('job_forms')
        .insert({
          business_id: resolvedBusinessId,
          name: template.title,
          form_type: sourceForm.form_type,
          fields: sourceForm.fields ?? [],
          sections: sourceForm.sections ?? [],
          signature_box: sourceForm.signature_box ?? null,
          requires_signature: sourceForm.requires_signature ?? false,
          recreation_mode: sourceForm.recreation_mode ?? 'standard',
          background_pages: [],
          page_number_start: sourceForm.page_number_start ?? 1,
          page_number_total_override: sourceForm.page_number_total_override ?? null,
          is_blank_template: true,
          available_to_other_businesses: false, // a copy isn't auto re-shared
        })
        .select('id')
        .single();
      if (insertErr || !newForm) return jsonResponse({ error: 'Could not create form: ' + insertErr?.message }, 500);

      const sourcePages: string[] = sourceForm.background_pages ?? [];
      const newPaths: string[] = [];
      for (let i = 0; i < sourcePages.length; i++) {
        const { data: fileBlob, error: dlErr } = await supabase.storage.from('job-form-media').download(sourcePages[i]);
        if (dlErr || !fileBlob) continue; // best-effort — one missing page shouldn't block the whole copy
        const bytes = new Uint8Array(await fileBlob.arrayBuffer());
        const newPath = `${resolvedBusinessId}/${newForm.id}/page-${i + 1}.png`;
        const { error: upErr } = await supabase.storage.from('job-form-media').upload(newPath, bytes, {
          contentType: 'image/png',
          upsert: true,
        });
        if (!upErr) newPaths.push(newPath);
      }

      if (newPaths.length > 0) {
        await supabase.from('job_forms').update({ background_pages: newPaths }).eq('id', newForm.id);
      }

      return jsonResponse({ success: true, job_form_id: newForm.id });
    }

    // Lets a business update which tags their own shared template carries,
    // any time after the initial share — full replace of the tag set
    // rather than incremental add/remove, simplest correct semantics for
    // a small multi-select UI.
    if (action === 'update_template_tags') {
      const { form_template_id, tag_ids } = body;
      if (!form_template_id) return jsonResponse({ error: 'form_template_id is required' }, 400);

      const { data: template, error: templateErr } = await supabase
        .from('form_templates')
        .select('id, business_id')
        .eq('id', form_template_id)
        .maybeSingle();
      if (templateErr || !template) return jsonResponse({ error: 'Template not found' }, 404);

      if (profile?.business_id && profile.business_id !== template.business_id) {
        return jsonResponse({ error: 'Not authorized to edit this template' }, 403);
      }

      const tagIds: number[] = Array.isArray(tag_ids) ? tag_ids : [];
      const { error: delErr } = await supabase.from('form_template_tags').delete().eq('form_template_id', form_template_id);
      if (delErr) return jsonResponse({ error: 'Could not clear old tags: ' + delErr.message }, 500);
      if (tagIds.length > 0) {
        const rows = tagIds.map((tagId) => ({ form_template_id, tag_id: tagId }));
        const { error: insErr } = await supabase.from('form_template_tags').insert(rows);
        if (insErr) return jsonResponse({ error: 'Could not save new tags: ' + insErr.message }, 500);
      }
      return jsonResponse({ success: true });
    }

    // form_tags INSERT is service-role-only by RLS design (same reasoning
    // as form_templates) — this is the only path any business has to add
    // a genuinely new tag to the shared, growing pool. Case-insensitive
    // dedupe so "Roofing" typed twice by two different businesses reuses
    // one row instead of fragmenting the tag list.
    if (action === 'create_tag') {
      const { name } = body;
      if (!name || typeof name !== 'string' || !name.trim()) {
        return jsonResponse({ error: 'name is required' }, 400);
      }
      const trimmed = name.trim();
      const { data: existing } = await supabase
        .from('form_tags')
        .select('id, name')
        .ilike('name', trimmed)
        .is('deleted_at', null)
        .maybeSingle();
      if (existing) return jsonResponse({ success: true, tag: existing });

      const { data: created, error: createErr } = await supabase
        .from('form_tags')
        .insert({ name: trimmed })
        .select('id, name')
        .single();
      if (createErr || !created) return jsonResponse({ error: 'Could not create tag: ' + createErr?.message }, 500);
      return jsonResponse({ success: true, tag: created });
    }

    return jsonResponse({ error: `Unknown action: ${action}` }, 400);
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});