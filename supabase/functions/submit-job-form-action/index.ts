import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const BUCKET = "job-form-media";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const contentType = req.headers.get("content-type") ?? "";
    let token: string | null = null;
    let submissionId: number | null = null;
    let action: string | null = null;
    let answers: any = null;
    let fieldId: string | null = null;
    let photoPath: string | null = null;
    let markerId: string | null = null;
    let photoAttachmentId: number | null = null;
    let signedByName: string | null = null;
    let file: File | null = null;
    let businessIdParam: number | null = null;
    let saveAsDefault = false;
    let imageType: string | null = null;
    let pageNumber: number | null = null;

    if (contentType.includes("multipart/form-data")) {
      const formData = await req.formData();
      token = formData.get("token") as string | null;
      const subIdRaw = formData.get("submission_id") as string | null;
      submissionId = subIdRaw ? parseInt(subIdRaw) : null;
      action = formData.get("action") as string | null;
      const answersRaw = formData.get("answers") as string | null;
      answers = answersRaw ? JSON.parse(answersRaw) : null;
      fieldId = formData.get("field_id") as string | null;
      photoPath = formData.get("photo_path") as string | null;
      signedByName = formData.get("signed_by_name") as string | null;
      markerId = formData.get("marker_id") as string | null;
      const photoAttachmentIdRaw = formData.get("photo_attachment_id") as string | null;
      photoAttachmentId = photoAttachmentIdRaw ? parseInt(photoAttachmentIdRaw) : null;
      file = formData.get("file") as File | null;
      const businessIdRaw = formData.get("business_id") as string | null;
      businessIdParam = businessIdRaw ? parseInt(businessIdRaw) : null;
      saveAsDefault = (formData.get("save_as_default") as string | null) === "true";
      imageType = formData.get("image_type") as string | null;
      const pageNumberRaw = formData.get("page_number") as string | null;
      pageNumber = pageNumberRaw ? parseInt(pageNumberRaw) : null;
    } else {
      const body = await req.json();
      token = body.token;
      submissionId = body.submission_id;
      action = body.action;
      answers = body.answers ?? null;
      fieldId = body.field_id ?? null;
      photoPath = body.photo_path ?? null;
      signedByName = body.signed_by_name ?? null;
      markerId = body.marker_id ?? null;
      photoAttachmentId = body.photo_attachment_id ?? null;
      businessIdParam = body.business_id ?? null;
      saveAsDefault = body.save_as_default === true;
      imageType = body.image_type ?? null;
    }

    const authHeader = req.headers.get("Authorization");

    if ((!token && !authHeader) || !submissionId || !action) {
      return new Response(JSON.stringify({ error: "submission_id, action, and either token or a session are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["save_answers", "upload_photo", "upload_signature", "upload_initials", "apply_saved_image", "clear_signature", "clear_initials", "delete_photo", "upload_marker_photo", "delete_marker_photo", "upload_rendered_page", "complete", "reopen_for_correction"];
    if (!validActions.includes(action)) {
      return new Response(JSON.stringify({ error: "Invalid action" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve caller: hub token (field) OR office session ────────────────
    let hubToken: { business_id: number; profile_id: number | null };
    let profile: { id: number; full_name: string } | null = null;

    if (token) {
      const { data: hubTokenRow, error: tokenError } = await supabase
        .from("employee_hub_tokens")
        .select("id, profile_id, business_id, revoked_at")
        .eq("token", token)
        .maybeSingle();

      if (tokenError || !hubTokenRow || hubTokenRow.revoked_at) {
        return new Response(JSON.stringify({ error: "This link is no longer valid." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      hubToken = { business_id: hubTokenRow.business_id, profile_id: hubTokenRow.profile_id };

      const { data: profileRow } = await supabase
        .from("profiles")
        .select("id, full_name")
        .eq("id", hubTokenRow.profile_id)
        .maybeSingle();
      profile = profileRow ?? null;
    } else {
      const { data: userData, error: userError } = await supabase.auth.getUser(
        authHeader!.replace("Bearer ", "")
      );
      if (userError || !userData?.user) {
        return new Response(JSON.stringify({ error: "Not authenticated." }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: sessionProfile, error: sessionProfileError } = await supabase
        .from("profiles")
        .select("id, full_name, business_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (sessionProfileError || !sessionProfile) {
        const { data: superuser } = await supabase
          .from("superusers")
          .select("user_id")
          .eq("user_id", userData.user.id)
          .maybeSingle();

        if (superuser && businessIdParam) {
          hubToken = { business_id: businessIdParam, profile_id: null };
        } else {
          return new Response(JSON.stringify({ error: "Profile not found." }), {
            status: 404,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      } else {
        hubToken = { business_id: sessionProfile.business_id, profile_id: sessionProfile.id };
        profile = { id: sessionProfile.id, full_name: sessionProfile.full_name };
      }
    }

    // ── 2. Load + validate submission belongs to this business ───────────────
    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, business_id, photo_urls, status, job_form_id, answers, appointment_id, rendered_page_urls")
      .eq("id", submissionId)
      .eq("business_id", hubToken.business_id)
      .is("deleted_at", null)
      .maybeSingle();

    if (subError || !submission) {
      return new Response(JSON.stringify({ error: "Job form submission not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── save_answers ───────────────────────────────────────────────────────
    if (action === "save_answers") {
      if (!answers) {
        return new Response(JSON.stringify({ error: "answers is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          answers,
          completed_by_profile_id: hubToken.profile_id,
          status: submission.status === "not_started" ? "in_progress" : submission.status,
        })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error saving answers: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── upload_photo ───────────────────────────────────────────────────────
    if (action === "upload_photo") {
      if (!file || !fieldId) {
        return new Response(JSON.stringify({ error: "file and field_id are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const ext = (file.name.split(".").pop() || "jpg").toLowerCase();
      const path = `${hubToken.business_id}/${submissionId}/${fieldId}-${Date.now()}.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type || "image/jpeg" });

      if (uploadError) {
        return new Response(JSON.stringify({ error: "Error uploading photo: " + uploadError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const updatedUrls = [...(submission.photo_urls ?? []), path];
      const currentAnswers = submission.answers ?? {};
      const existingFieldPhotos = Array.isArray(currentAnswers[fieldId]) ? currentAnswers[fieldId] : [];
      const updatedAnswers = { ...currentAnswers, [fieldId]: [...existingFieldPhotos, path] };

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          photo_urls: updatedUrls,
          answers: updatedAnswers,
          completed_by_profile_id: hubToken.profile_id,
          status: submission.status === "not_started" ? "in_progress" : submission.status,
        })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error saving photo reference: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, path }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── delete_photo ───────────────────────────────────────────────────────
    if (action === "delete_photo") {
      if (!fieldId || !photoPath) {
        return new Response(JSON.stringify({ error: "field_id and photo_path are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await supabase.storage.from(BUCKET).remove([photoPath]);

      const updatedUrls = (submission.photo_urls ?? []).filter((p: string) => p !== photoPath);
      const currentAnswers = submission.answers ?? {};
      const existingFieldPhotos = Array.isArray(currentAnswers[fieldId]) ? currentAnswers[fieldId] : [];
      const updatedAnswers = {
        ...currentAnswers,
        [fieldId]: existingFieldPhotos.filter((p: string) => p !== photoPath),
      };

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({ photo_urls: updatedUrls, answers: updatedAnswers })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error removing photo: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── upload_marker_photo ────────────────────────────────────────────────
    // Writes a real row into job_form_photo_attachments, keyed to a
    // photo_attachment_marker's id — deliberately separate from
    // upload_photo's photo_urls/answers array pattern, matching the
    // schema decision made when this table was built (per-photo RLS
    // scoping, clean individual soft-delete, real indexing at scale).
    if (action === "upload_marker_photo") {
      if (!file || !markerId) {
        return new Response(JSON.stringify({ error: "file and marker_id are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const ext = (file.name.split(".").pop() || "jpg").toLowerCase();
      const path = `${hubToken.business_id}/${submissionId}/marker-${markerId}-${Date.now()}.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type || "image/jpeg" });

      if (uploadError) {
        return new Response(JSON.stringify({ error: "Error uploading photo: " + uploadError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: inserted, error: insertError } = await supabase
        .from("job_form_photo_attachments")
        .insert({
          business_id: hubToken.business_id,
          job_form_id: submission.job_form_id,
          submission_id: submissionId,
          marker_id: markerId,
          storage_path: path,
          uploaded_by_profile_id: hubToken.profile_id,
        })
        .select("id")
        .single();

      if (insertError) {
        return new Response(JSON.stringify({ error: "Error saving photo reference: " + insertError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Marker photos don't drive required-field validation the way
      // field-based photos do (markers aren't in the fields array), but
      // any upload still counts as progress on the form.
      if (submission.status === "not_started") {
        await supabase
          .from("job_form_submissions")
          .update({ status: "in_progress", completed_by_profile_id: hubToken.profile_id })
          .eq("id", submissionId);
      }

      return new Response(JSON.stringify({ success: true, id: inserted.id, path }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── delete_marker_photo ────────────────────────────────────────────────
    if (action === "delete_marker_photo") {
      if (!photoAttachmentId) {
        return new Response(JSON.stringify({ error: "photo_attachment_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: attachment, error: fetchError } = await supabase
        .from("job_form_photo_attachments")
        .select("id, storage_path, submission_id")
        .eq("id", photoAttachmentId)
        .eq("submission_id", submissionId)
        .is("deleted_at", null)
        .maybeSingle();

      if (fetchError || !attachment) {
        return new Response(JSON.stringify({ error: "Photo not found." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await supabase.storage.from(BUCKET).remove([attachment.storage_path]);

      const { error: updateError } = await supabase
        .from("job_form_photo_attachments")
        .update({ deleted_at: new Date().toISOString() })
        .eq("id", photoAttachmentId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error removing photo: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── upload_rendered_page ────────────────────────────────────────────────
    // Real screenshot of one background page's fully-rendered canvas (Fill
    // Screen's RepaintBoundary.toImage() capture), uploaded per page at
    // submit time. Stored as a page-ordered array so the PDF generator can
    // use these captured images directly instead of re-deriving the same
    // layout server-side from raw field coordinates — eliminates drift
    // between what the tech actually saw and what the PDF shows.
    if (action === "upload_rendered_page") {
      if (!file || !pageNumber || pageNumber < 1) {
        return new Response(JSON.stringify({ error: "file and a valid page_number are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const path = `${hubToken.business_id}/${submissionId}/rendered-page-${pageNumber}-${Date.now()}.png`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type || "image/png" });

      if (uploadError) {
        return new Response(JSON.stringify({ error: "Error uploading rendered page: " + uploadError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const existingRendered: string[] = Array.isArray(submission.rendered_page_urls)
        ? [...submission.rendered_page_urls]
        : [];
      // Old renders for this page (if the tech re-submits after a
      // correction) get removed from storage rather than left as orphans —
      // this array is always the CURRENT true state, not a history.
      const staleIndex = pageNumber - 1;
      if (existingRendered[staleIndex]) {
        await supabase.storage.from(BUCKET).remove([existingRendered[staleIndex]]);
      }
      existingRendered[staleIndex] = path;

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({ rendered_page_urls: existingRendered })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error saving rendered page reference: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, path }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── upload_signature ───────────────────────────────────────────────────
    if (action === "upload_signature") {
      if (!file) {
        return new Response(JSON.stringify({ error: "file is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const path = `${hubToken.business_id}/${submissionId}/signature-${Date.now()}.png`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type || "image/png" });

      if (uploadError) {
        return new Response(JSON.stringify({ error: "Error uploading signature: " + uploadError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          signature_url: path,
          signed_by_name: signedByName ?? profile?.full_name ?? null,
          signed_at: new Date().toISOString(),
        })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error saving signature reference: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (saveAsDefault && hubToken.profile_id) {
        await supabase
          .from("profiles")
          .update({ saved_signature_url: path })
          .eq("id", hubToken.profile_id);
      }

      return new Response(JSON.stringify({ success: true, path }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── upload_initials ───────────────────────────────────────────────────
    // Deliberately separate from upload_signature: each Initials cell has
    // its own field_id and stores into answers[fieldId], not the single
    // form-level signature_url column — every cell independently signed,
    // never auto-filled from another cell.
    if (action === "upload_initials") {
      if (!file || !fieldId) {
        return new Response(JSON.stringify({ error: "file and field_id are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const path = `${hubToken.business_id}/${submissionId}/initials-${fieldId}-${Date.now()}.png`;

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { contentType: file.type || "image/png" });

      if (uploadError) {
        return new Response(JSON.stringify({ error: "Error uploading initials: " + uploadError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const currentAnswers = submission.answers ?? {};
      const updatedAnswers = { ...currentAnswers, [fieldId]: path };

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          answers: updatedAnswers,
          completed_by_profile_id: hubToken.profile_id,
          status: submission.status === "not_started" ? "in_progress" : submission.status,
        })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error saving initials reference: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (saveAsDefault && hubToken.profile_id) {
        await supabase
          .from("profiles")
          .update({ saved_initials_url: path })
          .eq("id", hubToken.profile_id);
      }

      return new Response(JSON.stringify({ success: true, path }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── apply_saved_image ───────────────────────────────────────────────────
    // Pulls in the tech's already-saved signature/initials (profile first,
    // business default as fallback) without re-uploading — just references
    // the same storage path.
    if (action === "apply_saved_image") {
      if (!imageType || (imageType !== "signature" && imageType !== "initials")) {
        return new Response(JSON.stringify({ error: "image_type must be 'signature' or 'initials'" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (imageType === "initials" && !fieldId) {
        return new Response(JSON.stringify({ error: "field_id is required for initials" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      let savedPath: string | null = null;
      if (hubToken.profile_id) {
        const { data: profileRow } = await supabase
          .from("profiles")
          .select("saved_signature_url, saved_initials_url")
          .eq("id", hubToken.profile_id)
          .maybeSingle();
        savedPath = imageType === "signature" ? profileRow?.saved_signature_url ?? null : profileRow?.saved_initials_url ?? null;
      }
      if (!savedPath) {
        const { data: bizRow } = await supabase
          .from("businesses")
          .select("default_signature_url, default_initials_url")
          .eq("id", hubToken.business_id)
          .maybeSingle();
        savedPath = imageType === "signature" ? bizRow?.default_signature_url ?? null : bizRow?.default_initials_url ?? null;
      }

      if (!savedPath) {
        return new Response(JSON.stringify({ error: "No saved image available." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (imageType === "signature") {
        const { error: updateError } = await supabase
          .from("job_form_submissions")
          .update({
            signature_url: savedPath,
            signed_by_name: signedByName ?? profile?.full_name ?? null,
            signed_at: new Date().toISOString(),
          })
          .eq("id", submissionId);
        if (updateError) {
          return new Response(JSON.stringify({ error: "Error applying signature: " + updateError.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      } else {
        const currentAnswers = submission.answers ?? {};
        const updatedAnswers = { ...currentAnswers, [fieldId as string]: savedPath };
        const { error: updateError } = await supabase
          .from("job_form_submissions")
          .update({
            answers: updatedAnswers,
            completed_by_profile_id: hubToken.profile_id,
            status: submission.status === "not_started" ? "in_progress" : submission.status,
          })
          .eq("id", submissionId);
        if (updateError) {
          return new Response(JSON.stringify({ error: "Error applying initials: " + updateError.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      }

      return new Response(JSON.stringify({ success: true, path: savedPath }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── clear_signature ─────────────────────────────────────────────────────
    // Fully unsigns the form-level signature — distinct from clearing the
    // in-progress drawing pad client-side. Lets a tech back out of a wrong
    // signature entirely and start over.
    if (action === "clear_signature") {
      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({ signature_url: null, signed_by_name: null, signed_at: null })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error clearing signature: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── clear_initials ──────────────────────────────────────────────────────
    // Removes a single Initials cell's saved answer, keyed by field_id —
    // every other cell on the form is untouched.
    if (action === "clear_initials") {
      if (!fieldId) {
        return new Response(JSON.stringify({ error: "field_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const currentAnswers = { ...(submission.answers ?? {}) };
      delete currentAnswers[fieldId];

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({ answers: currentAnswers })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error clearing initials: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── complete ───────────────────────────────────────────────────────────
    if (action === "complete") {
      const { data: jobForm } = await supabase
        .from("job_forms")
        .select("fields, requires_signature")
        .eq("id", submission.job_form_id)
        .maybeSingle();

      const fields: any[] = jobForm?.fields ?? [];
      const finalAnswers = answers ?? {};
      const missingRequired = fields.filter((f: any) => {
        if (!f.required) return false;
        const val = finalAnswers[f.id];
        if (f.type === "photo") {
          return !Array.isArray(val) || val.length === 0;
        }
        return val === null || val === undefined || val === "";
      });

      if (missingRequired.length > 0) {
        return new Response(
          JSON.stringify({
            error: "required_fields_missing",
            message: "Some required fields are still blank.",
            missing_fields: missingRequired.map((f: any) => f.label),
          }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: currentSub } = await supabase
        .from("job_form_submissions")
        .select("signature_url")
        .eq("id", submissionId)
        .maybeSingle();

      if (jobForm?.requires_signature && !currentSub?.signature_url) {
        return new Response(
          JSON.stringify({ error: "signature_required", message: "This form requires a signature before completing." }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          answers: finalAnswers,
          status: "completed",
          completed_by_profile_id: hubToken.profile_id,
        })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error completing form: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Fire job_form_completed automation trigger — non-blocking, never fails the request
      try {
        let leadName: string | null = null;
        let leadPhone: string | null = null;
        let leadEmail: string | null = null;
        if (submission.appointment_id) {
          const { data: appt } = await supabase
            .from("appointments")
            .select("lead_name, lead_phone, lead_email")
            .eq("id", submission.appointment_id)
            .maybeSingle();
          leadName = appt?.lead_name ?? null;
          leadPhone = appt?.lead_phone ?? null;
          leadEmail = appt?.lead_email ?? null;
        }

        await fetch("https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            trigger_type: "job_form_completed",
            business_id: hubToken.business_id,
            payload: {
              submission_id: submissionId,
              job_form_id: submission.job_form_id,
              appointment_id: submission.appointment_id,
              completed_by_profile_id: hubToken.profile_id,
              completed_by_name: profile?.full_name ?? null,
              lead_name: leadName,
              phone: leadPhone,
              email: leadEmail,
            },
          }),
        });
      } catch (e) {
        console.error("job_form_completed automation error:", e);
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── reopen_for_correction ─────────────────────────────────────────────
    if (action === "reopen_for_correction") {
      if (submission.status !== "completed") {
        return new Response(JSON.stringify({ error: "Only completed forms can be sent back for correction." }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({ status: "in_progress" })
        .eq("id", submissionId);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error reopening form: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Fallback — validActions already guarantees action matches one of the
    // blocks above, but TypeScript can't infer that from the code shape,
    // so without this the function's return type is Response | undefined.
    return new Response(JSON.stringify({ error: "Unhandled action" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});