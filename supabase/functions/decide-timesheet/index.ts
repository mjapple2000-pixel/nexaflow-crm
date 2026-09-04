import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAILGUN_API_KEY = Deno.env.get("MAILGUN_API_KEY") ?? "";
const MAILGUN_DOMAIN = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

// Internal ops alert — for failures that shouldn't ever fail silently
// (e.g. a notification email that never went out). Never throws itself:
// every step is independently wrapped so a broken alert path can't take
// down the calling function's actual work.
const INTERNAL_ALERT_EMAIL = "vantagecaretech@gmail.com";

// deno-lint-ignore no-explicit-any
async function sendInternalAlert(
  supabase: any,
  source: string,
  businessId: number | null,
  detail: unknown,
  errorMessage: string,
) {
  try {
    await supabase.from("system_alert_log").insert({
      source,
      business_id: businessId,
      detail,
      error_message: errorMessage,
    });
  } catch (logErr) {
    console.error(`sendInternalAlert: failed to write system_alert_log for ${source}:`, logErr);
  }

  if (!MAILGUN_API_KEY) return;
  try {
    const form = new URLSearchParams();
    form.append("from", `NexaFlow Alerts <no-reply@${MAILGUN_DOMAIN}>`);
    form.append("to", INTERNAL_ALERT_EMAIL);
    form.append("subject", `⚠️ NexaFlow Alert: ${source}`);
    form.append("text", `${errorMessage}\n\nDetail: ${JSON.stringify(detail, null, 2)}`);
    await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
  } catch (alertErr) {
    console.error(`sendInternalAlert: failed to send alert email for ${source}:`, alertErr);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = "https://rllriopqojaraceytdno.supabase.co";
    const supabaseServiceKey = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08;

    const supabaseAuth = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userError } = await supabaseAuth.auth.getUser();
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid or expired session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const callerUserId = userData.user.id;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return new Response(JSON.stringify({ error: "Missing request body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const {
      target_user_id,
      week_start,
      week_end,
      decision,
      reason,
      business_id: requestedBusinessId,
    } = body as {
      target_user_id?: string;
      week_start?: string;
      week_end?: string;
      decision?: string;
      reason?: string;
      business_id?: number | string;
    };

    if (!target_user_id || !week_start || !week_end) {
      return new Response(JSON.stringify({ error: "target_user_id, week_start, and week_end are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (decision !== "approved" && decision !== "rejected") {
      return new Response(JSON.stringify({ error: "decision must be 'approved' or 'rejected'" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (decision === "rejected" && (!reason || !reason.trim())) {
      return new Response(JSON.stringify({ error: "A reason is required to reject a timesheet" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Resolve caller's business + permission ──────────────────────
    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id, role, permissions")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let canManageTimesheets: boolean;

    if (profile?.business_id) {
      businessId = profile.business_id;
      const perms = (profile.permissions ?? {}) as Record<string, unknown>;
      canManageTimesheets = profile.role === "owner" || profile.role === "admin" || perms.manage_timesheets === true;
    } else {
      const { data: superuserRow } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", callerUserId)
        .maybeSingle();

      if (!superuserRow || !requestedBusinessId) {
        return new Response(JSON.stringify({ error: "No business association found" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      businessId = Number(requestedBusinessId);
      canManageTimesheets = true;
    }

    if (!canManageTimesheets) {
      return new Response(JSON.stringify({ error: "You do not have permission to approve or reject timesheets" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // TS-11: approve/reject is Pro (or beta) only — same gate the
    // Hub-side submit button checks. Enforced here too since this
    // endpoint doesn't go through the Hub token path.
    const { data: approvalWorkflowAllowed } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "timesheet_approval_workflow" });

    if (!approvalWorkflowAllowed) {
      return new Response(JSON.stringify({ error: "Timesheet approval workflow is not available on your current plan" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // The owner can decide their own timesheet — there's no one else to
    // approve it for a solo operator. Everyone else still needs a
    // second party, even with a stray manage_timesheets grant.
    if (target_user_id === callerUserId && profile?.role !== "owner") {
      return new Response(JSON.stringify({ error: "You can't approve or reject your own timesheet" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Locate the period and the employee's submitted status ────────
    const { data: period, error: periodErr } = await supabase
      .from("pay_periods")
      .select("id")
      .eq("business_id", businessId)
      .eq("week_start", week_start)
      .eq("week_end", week_end)
      .maybeSingle();

    if (periodErr || !period) {
      return new Response(JSON.stringify({ error: "No pay period found for that range" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: statusRow, error: statusErr } = await supabase
      .from("employee_pay_period_status")
      .select("id, status, user_id")
      .eq("pay_period_id", period.id)
      .eq("user_id", target_user_id)
      .maybeSingle();

    if (statusErr || !statusRow) {
      return new Response(JSON.stringify({ error: "No submission found for this employee in this period" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (statusRow.status !== "submitted") {
      return new Response(
        JSON.stringify({ error: `This timesheet is currently '${statusRow.status}', not 'submitted' — nothing to decide.` }),
        { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // decided_by has an FK to profiles(user_id) — superuser has no
    // profiles row, so fall back to null for a superuser-driven decision.
    const decidedByUserId = profile?.business_id ? callerUserId : null;
    const nowIso = new Date().toISOString();

    const updatePayload: Record<string, unknown> =
      decision === "approved"
        ? { status: "approved", approved_at: nowIso, approved_by: decidedByUserId, rejected_at: null, rejected_by: null, rejection_reason: null }
        : { status: "rejected", rejected_at: nowIso, rejected_by: decidedByUserId, rejection_reason: reason!.trim(), approved_at: null, approved_by: null };

    const { data: updated, error: updateErr } = await supabase
      .from("employee_pay_period_status")
      .update(updatePayload)
      .eq("id", statusRow.id)
      .select()
      .maybeSingle();

    if (updateErr) {
      return new Response(JSON.stringify({ error: "Failed to record decision: " + updateErr.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    await supabase.from("pay_period_status_history").insert({
      business_id: businessId,
      pay_period_id: period.id,
      user_id: target_user_id,
      from_status: "submitted",
      to_status: decision,
      changed_by: decidedByUserId,
      reason: decision === "rejected" ? reason!.trim() : null,
    });

    // Auto-lock trigger fires server-side on the UPDATE above if this
    // was the last outstanding approval for the period. Check the
    // result so the UI can reflect it immediately without a refetch.
    const { data: periodAfter } = await supabase
      .from("pay_periods")
      .select("locked_at")
      .eq("id", period.id)
      .maybeSingle();

    // ── Notify the employee of the outcome. Never blocks the decision
    // itself, but a failure here is never silent — it goes to
    // system_alert_log + an internal email, same as any other
    // notification failure in this app.
    try {
      const { data: employeeProfile } = await supabase
        .from("profiles")
        .select("email, full_name")
        .eq("user_id", target_user_id)
        .maybeSingle();

      const { data: business } = await supabase
        .from("businesses")
        .select("business_name")
        .eq("id", businessId)
        .maybeSingle();

      const businessName = business?.business_name || "your business";

      if (!employeeProfile?.email) {
        await sendInternalAlert(
          supabase,
          "decide-timesheet:notify-employee",
          businessId,
          { target_user_id, week_start, week_end, decision },
          "Employee has no email on file — decision was recorded but they were never notified.",
        );
      } else if (MAILGUN_API_KEY) {
        const lines =
          decision === "approved"
            ? [
                `Your timesheet for ${week_start} to ${week_end} has been approved.`,
                "",
                `— ${businessName}`,
              ]
            : [
                `Your timesheet for ${week_start} to ${week_end} was rejected and needs changes.`,
                "",
                `Reason: ${reason!.trim()}`,
                "",
                "Please make the needed corrections and resubmit.",
                "",
                `— ${businessName}`,
              ];

        const form = new URLSearchParams();
        form.append("from", `${businessName} <no-reply@${MAILGUN_DOMAIN}>`);
        form.append("to", employeeProfile.email);
        form.append(
          "subject",
          decision === "approved" ? "✅ Timesheet Approved" : "⚠️ Timesheet Needs Changes"
        );
        form.append("text", lines.join("\n"));

        const mailgunRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
          method: "POST",
          headers: {
            "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: form.toString(),
        });

        if (!mailgunRes.ok) {
          const mailgunErrText = await mailgunRes.text();
          await sendInternalAlert(
            supabase,
            "decide-timesheet:notify-employee",
            businessId,
            { target_user_id, week_start, week_end, decision, mailgun_status: mailgunRes.status },
            `Mailgun returned ${mailgunRes.status}: ${mailgunErrText}`,
          );
        }
      }
    } catch (notifyErr) {
      await sendInternalAlert(
        supabase,
        "decide-timesheet:notify-employee",
        businessId,
        { target_user_id, week_start, week_end, decision },
        notifyErr instanceof Error ? notifyErr.message : String(notifyErr),
      );
    }

    return new Response(
      JSON.stringify({ success: true, status: updated, period_locked: periodAfter?.locked_at != null }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});