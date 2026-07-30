import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const BUCKET = "job-form-media";
const SIGNED_URL_EXPIRY_SECONDS = 3600;

async function getSignedUrl(path: string | null): Promise<string | null> {
  if (!path) return null;
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(path, SIGNED_URL_EXPIRY_SECONDS);
  if (error) {
    console.error("Signed URL error for", path, error.message);
    return null;
  }
  return data?.signedUrl ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get("token");
    const viewToken = url.searchParams.get("view_token");
    const submissionIdParam = url.searchParams.get("submission_id");
    let submissionId = submissionIdParam ? parseInt(submissionIdParam) : null;
    const authHeader = req.headers.get("Authorization");
    const businessIdParam = url.searchParams.get("business_id");

    if (!viewToken && (!submissionId || (!token && !authHeader))) {
      return new Response(JSON.stringify({ error: "submission_id and either token or a session are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve caller: view token (read-only lead link), hub token
    // (field), OR Supabase session (office). view_token identifies its OWN
    // submission directly — a lead's link never carries a submission_id,
    // only the token — and is deliberately never given a profileId, since
    // there's no concept of "which tech is viewing" here and this path
    // must never be able to save anything. This function only ever reads,
    // so no further write-guarding is needed beyond that.
    let businessId: number;
    let profileId: number | null = null;

    if (viewToken) {
      const { data: viewSub, error: viewSubError } = await supabase
        .from("job_form_submissions")
        .select("id, business_id, status")
        .eq("view_token", viewToken)
        .is("deleted_at", null)
        .maybeSingle();

      if (viewSubError || !viewSub) {
        return new Response(JSON.stringify({ error: "This link is no longer valid." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (viewSub.status !== "completed") {
        return new Response(JSON.stringify({ error: "This form is not ready to view yet." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      businessId = viewSub.business_id;
      submissionId = viewSub.id;
    } else if (token) {
      const { data: hubToken, error: tokenError } = await supabase
        .from("employee_hub_tokens")
        .select("id, profile_id, business_id, revoked_at")
        .eq("token", token)
        .maybeSingle();

      if (tokenError || !hubToken || hubToken.revoked_at) {
        return new Response(JSON.stringify({ error: "This link is no longer valid." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      businessId = hubToken.business_id;
      profileId = hubToken.profile_id;
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
      const { data: profile, error: profileError } = await supabase
        .from("profiles")
        .select("id, business_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (profileError || !profile) {
        const { data: superuser } = await supabase
          .from("superusers")
          .select("user_id")
          .eq("user_id", userData.user.id)
          .maybeSingle();

        if (superuser && businessIdParam) {
          businessId = parseInt(businessIdParam);
        } else {
          return new Response(JSON.stringify({ error: "Profile not found." }), {
            status: 404,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      } else {
        businessId = profile.business_id;
        profileId = profile.id;
      }
    }

    // ── 2. Load submission, scoped to this business ──────────────────────────
    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, job_form_id, appointment_id, status, answers, photo_urls, signature_url, signed_by_name, signed_at, business_id, pdf_url, submission_label, extra_pages")
      .eq("id", submissionId)
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .maybeSingle();

    if (subError) {
      console.error("get-job-form-data submission lookup error:", subError);
    }

    if (!submission) {
      return new Response(JSON.stringify({ error: "Job form submission not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 3. Load the template ──────────────────────────────────────────────────
    const { data: jobForm, error: formError } = await supabase
      .from("job_forms")
      .select("id, name, form_type, fields, requires_signature, background_pages, photo_attachment_markers, signature_box")
      .eq("id", submission.job_form_id)
      .eq("business_id", businessId)
      .maybeSingle();

    if (formError || !jobForm) {
      return new Response(JSON.stringify({ error: "Job form template not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 3b. Signed URLs for private bucket display ────────────────────────────
    const rawPhotoUrls: string[] = submission.photo_urls ?? [];
    const signedUrlEntries = await Promise.all(
      rawPhotoUrls.map(async (p) => [p, await getSignedUrl(p)] as [string, string | null])
    );
    const photoSignedUrlMap: Record<string, string | null> = Object.fromEntries(signedUrlEntries);
    const signatureSignedUrl = await getSignedUrl(submission.signature_url);
    const pdfSignedUrl = await getSignedUrl(submission.pdf_url);

    // ── 3c. Page image signed URLs — Fill Screen needs these to render
    // the actual form background and overlay tappable photo-marker icons
    // on it, same signing pattern used for photos/signature/pdf above.
    const backgroundPages: string[] = jobForm.background_pages ?? [];
    const pageUrls = await Promise.all(backgroundPages.map((p) => getSignedUrl(p)));

    // Sign each extra-page row's initials image, if any — mirrors the
    // pattern used for initialsSignedUrls on real template fields, just
    // scoped to this submission's own extra_pages structure instead.
    const rawExtraPages: any[] = submission.extra_pages ?? [];
    const extraPagesSigned = await Promise.all(
      rawExtraPages.map(async (p: any) => ({
        ...p,
        sections: await Promise.all(
          (p.sections ?? []).map(async (s: any) => ({
            ...s,
            initials_signed_url: s.initials_path ? await getSignedUrl(s.initials_path) : null,
          }))
        ),
      }))
    );

    // ── 3d. Existing marker photos — grouped by marker_id so the Fill
    // Screen's gallery bottom sheet can show "already uploaded for Roof"
    // without a separate round-trip. Real rows in job_form_photo_attachments
    // (not the photo_urls/answers array pattern field-based photos use),
    // scoped to this specific submission.
    const { data: markerPhotoRows, error: markerPhotoError } = await supabase
      .from("job_form_photo_attachments")
      .select("id, marker_id, storage_path, created_at")
      .eq("submission_id", submissionId)
      .is("deleted_at", null)
      .order("created_at", { ascending: true });

    if (markerPhotoError) {
      console.error("get-job-form-data marker photo lookup error:", markerPhotoError);
    }

    const markerPhotosMap: Record<string, { id: number; signed_url: string | null }[]> = {};
    for (const row of markerPhotoRows ?? []) {
      const signedUrl = await getSignedUrl(row.storage_path);
      if (!markerPhotosMap[row.marker_id]) markerPhotosMap[row.marker_id] = [];
      markerPhotosMap[row.marker_id].push({ id: row.id, signed_url: signedUrl });
    }

    // ── 3e. Per-field Initials answers — each is_initials field's answer
    // is a single storage path in submission.answers[field.id] (not a list,
    // unlike photo fields). Signed individually so the Fill Screen can show
    // what's already signed without a separate round-trip.
    const initialsFields: any[] = (jobForm.fields ?? []).filter((f: any) => f.is_initials === true);
    const initialsSignedUrls: Record<string, string | null> = {};
    for (const f of initialsFields) {
      const answerPath = (submission.answers as any)?.[f.id];
      if (typeof answerPath === "string" && answerPath) {
        initialsSignedUrls[f.id] = await getSignedUrl(answerPath);
      }
    }

    // ── 3f. Saved signature/initials for this tech — profile first,
    // business default as fallback, per the design decided when
    // saved_signature_url/saved_initials_url were added.
    let savedSignatureUrl: string | null = null;
    let savedInitialsUrl: string | null = null;
    if (profileId) {
      const { data: profileRow } = await supabase
        .from("profiles")
        .select("saved_signature_url, saved_initials_url")
        .eq("id", profileId)
        .maybeSingle();
      savedSignatureUrl = profileRow?.saved_signature_url ?? null;
      savedInitialsUrl = profileRow?.saved_initials_url ?? null;
    }
    if (!savedSignatureUrl || !savedInitialsUrl) {
      const { data: bizRow } = await supabase
        .from("businesses")
        .select("default_signature_url, default_initials_url")
        .eq("id", businessId)
        .maybeSingle();
      if (!savedSignatureUrl) savedSignatureUrl = bizRow?.default_signature_url ?? null;
      if (!savedInitialsUrl) savedInitialsUrl = bizRow?.default_initials_url ?? null;
    }
    const savedSignatureSignedUrl = await getSignedUrl(savedSignatureUrl);
    const savedInitialsSignedUrl = await getSignedUrl(savedInitialsUrl);

    // ── 4. Appointment context (for header display) ──────────────────────────
    let appointmentInfo: any = null;
    if (submission.appointment_id) {
      const { data: appt } = await supabase
        .from("appointments")
        .select("appointment_type, lead_name, location")
        .eq("id", submission.appointment_id)
        .eq("business_id", businessId)
        .maybeSingle();
      appointmentInfo = appt ?? null;
    }

    return new Response(
      JSON.stringify({
        submission_id: submission.id,
        status: submission.status,
        submission_label: submission.submission_label ?? null,
        answers: submission.answers ?? {},
        photo_urls: rawPhotoUrls,
        photo_signed_urls: photoSignedUrlMap,
        signature_url: submission.signature_url,
        signature_signed_url: signatureSignedUrl,
        pdf_url: submission.pdf_url,
        pdf_signed_url: pdfSignedUrl,
        signed_by_name: submission.signed_by_name,
        signed_at: submission.signed_at,
        form_name: jobForm.name,
        form_type: jobForm.form_type,
        fields: jobForm.fields ?? [],
        requires_signature: jobForm.requires_signature === true,
        signature_box: jobForm.signature_box ?? null,
        page_urls: pageUrls,
        photo_attachment_markers: jobForm.photo_attachment_markers ?? [],
        extra_pages: extraPagesSigned,
        marker_photos: markerPhotosMap,
        initials_signed_urls: initialsSignedUrls,
        saved_signature_signed_url: savedSignatureSignedUrl,
        saved_initials_signed_url: savedInitialsSignedUrl,
        appointment_type: appointmentInfo?.appointment_type ?? null,
        lead_name: appointmentInfo?.lead_name ?? null,
        location: appointmentInfo?.location ?? null,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});