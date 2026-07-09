import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get("token");
    const submissionIdParam = url.searchParams.get("submission_id");
    const submissionId = submissionIdParam ? parseInt(submissionIdParam) : null;

    if (!token || !submissionId) {
      return new Response(JSON.stringify({ error: "token and submission_id are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve token ─────────────────────────────────────────────────────
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

    // ── 2. Load submission, scoped to this business ──────────────────────────
    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, job_form_id, appointment_id, status, answers, photo_urls, signature_url, signed_by_name, signed_at, business_id")
      .eq("id", submissionId)
      .eq("business_id", hubToken.business_id)
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
      .select("id, name, form_type, fields, requires_signature")
      .eq("id", submission.job_form_id)
      .eq("business_id", hubToken.business_id)
      .maybeSingle();

    if (formError || !jobForm) {
      return new Response(JSON.stringify({ error: "Job form template not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 4. Appointment context (for header display) ──────────────────────────
    let appointmentInfo: any = null;
    if (submission.appointment_id) {
      const { data: appt } = await supabase
        .from("appointments")
        .select("appointment_type, lead_name, location")
        .eq("id", submission.appointment_id)
        .eq("business_id", hubToken.business_id)
        .maybeSingle();
      appointmentInfo = appt ?? null;
    }

    return new Response(
      JSON.stringify({
        submission_id: submission.id,
        status: submission.status,
        answers: submission.answers ?? {},
        photo_urls: submission.photo_urls ?? [],
        signature_url: submission.signature_url,
        signed_by_name: submission.signed_by_name,
        signed_at: submission.signed_at,
        form_name: jobForm.name,
        form_type: jobForm.form_type,
        fields: jobForm.fields ?? [],
        requires_signature: jobForm.requires_signature === true,
        appointment: appointmentInfo,
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