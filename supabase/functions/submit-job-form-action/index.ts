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
    let signedByName: string | null = null;
    let file: File | null = null;
    let businessIdParam: number | null = null;

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
      file = formData.get("file") as File | null;
      const businessIdRaw = formData.get("business_id") as string | null;
      businessIdParam = businessIdRaw ? parseInt(businessIdRaw) : null;
    } else {
      const body = await req.json();
      token = body.token;
      submissionId = body.submission_id;
      action = body.action;
      answers = body.answers ?? null;
      fieldId = body.field_id ?? null;
      photoPath = body.photo_path ?? null;
      signedByName = body.signed_by_name ?? null;
      businessIdParam = body.business_id ?? null;
    }

    const authHeader = req.headers.get("Authorization");

    if ((!token && !authHeader) || !submissionId || !action) {
      return new Response(JSON.stringify({ error: "submission_id, action, and either token or a session are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["save_answers", "upload_photo", "upload_signature", "delete_photo", "complete", "reopen_for_correction"];
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
      .select("id, business_id, photo_urls, status, job_form_id, answers, appointment_id")
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
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});