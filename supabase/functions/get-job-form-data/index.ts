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
    const submissionIdParam = url.searchParams.get("submission_id");
    const submissionId = submissionIdParam ? parseInt(submissionIdParam) : null;
    const authHeader = req.headers.get("Authorization");
    const businessIdParam = url.searchParams.get("business_id");

    if (!submissionId || (!token && !authHeader)) {
      return new Response(JSON.stringify({ error: "submission_id and either token or a session are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve caller: hub token (field) OR Supabase session (office) ────
    let businessId: number;

    if (token) {
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
        .select("business_id")
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
      }
    }

    // ── 2. Load submission, scoped to this business ──────────────────────────
    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, job_form_id, appointment_id, status, answers, photo_urls, signature_url, signed_by_name, signed_at, business_id, pdf_url")
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
      .select("id, name, form_type, fields, requires_signature, background_pages, photo_attachment_markers")
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
        page_urls: pageUrls,
        photo_attachment_markers: jobForm.photo_attachment_markers ?? [],
        marker_photos: markerPhotosMap,
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