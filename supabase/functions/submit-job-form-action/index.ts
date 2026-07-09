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
    let signedByName: string | null = null;
    let file: File | null = null;

    if (contentType.includes("multipart/form-data")) {
      const formData = await req.formData();
      token = formData.get("token") as string | null;
      const subIdRaw = formData.get("submission_id") as string | null;
      submissionId = subIdRaw ? parseInt(subIdRaw) : null;
      action = formData.get("action") as string | null;
      const answersRaw = formData.get("answers") as string | null;
      answers = answersRaw ? JSON.parse(answersRaw) : null;
      fieldId = formData.get("field_id") as string | null;
      signedByName = formData.get("signed_by_name") as string | null;
      file = formData.get("file") as File | null;
    } else {
      const body = await req.json();
      token = body.token;
      submissionId = body.submission_id;
      action = body.action;
      answers = body.answers ?? null;
      fieldId = body.field_id ?? null;
      signedByName = body.signed_by_name ?? null;
    }

    if (!token || !submissionId || !action) {
      return new Response(JSON.stringify({ error: "token, submission_id, and action are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["save_answers", "upload_photo", "upload_signature", "complete"];
    if (!validActions.includes(action)) {
      return new Response(JSON.stringify({ error: "Invalid action" }), {
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

    const { data: profile } = await supabase
      .from("profiles")
      .select("id, full_name")
      .eq("id", hubToken.profile_id)
      .maybeSingle();

    // ── 2. Load + validate submission belongs to this business ───────────────
    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, business_id, photo_urls, status, job_form_id")
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
      const { error: updateError } = await supabase
        .from("job_form_submissions")
        .update({
          photo_urls: updatedUrls,
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

      return new Response(JSON.stringify({ success: true, path }), {
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

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});