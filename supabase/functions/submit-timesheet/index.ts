import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAILGUN_API_KEY = Deno.env.get("MAILGUN_API_KEY") ?? "";
const MAILGUN_DOMAIN = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

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
      week_start,
      week_end,
      target_user_id: requestedTargetUserId,
      business_id: requestedBusinessId,
    } = body as {
      week_start?: string;
      week_end?: string;
      target_user_id?: string;
      business_id?: number | string;
    };

    if (!week_start || !week_end) {
      return new Response(JSON.stringify({ error: "week_start and week_end are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (week_end < week_start) {
      return new Response(JSON.stringify({ error: "week_end must be on or after week_start" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Resolve caller's business + permission ──────────────────────
    const { data: profile } = await supabase
      .from("profiles")
      .select("id, business_id, role, full_name, permissions")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let canManageTimesheets: boolean;
    let isSuperuserCaller = false;

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
      isSuperuserCaller = true;
    }

    // An employee submits their own timesheet by default. Submitting on
    // behalf of someone else requires manage_timesheets — same gate as
    // TS-02's admin manual entry.
    const targetUserId = requestedTargetUserId ?? callerUserId;
    if (targetUserId !== callerUserId && !canManageTimesheets) {
      return new Response(JSON.stringify({ error: "You do not have permission to submit on behalf of another employee" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Plan-tier gate: Timesheets & Payroll requires Growth+ ──────────
    if (!isSuperuserCaller) {
      const { data: hasTimeTracking, error: gateErr } = await supabase.rpc("check_plan_feature", {
        p_business_id: businessId,
        p_feature: "time_tracking",
      });
      if (gateErr) {
        return new Response(JSON.stringify({ error: "Failed to verify plan access: " + gateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!hasTimeTracking) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheets & Payroll requires the Growth plan or higher.",
          upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
        }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // Verify target employee actually belongs to this business
    const { data: targetProfile } = await supabase
      .from("profiles")
      .select("user_id, full_name, business_id")
      .eq("user_id", targetUserId)
      .maybeSingle();

    if (!targetProfile || targetProfile.business_id !== businessId) {
      return new Response(JSON.stringify({ error: "Target team member not found in your business" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Find or create the business-wide pay_periods row for this range.
    // Periods are created lazily on first submission or first lock,
    // whichever happens first — same upsert-by-week_start convention
    // the office Pay Period lock controls already use.
    const { data: existingPeriod, error: periodFetchErr } = await supabase
      .from("pay_periods")
      .select("id, week_start, week_end, locked_at")
      .eq("business_id", businessId)
      .eq("week_start", week_start)
      .maybeSingle();

    if (periodFetchErr) {
      return new Response(JSON.stringify({ error: "Failed to look up pay period: " + periodFetchErr.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let payPeriodId: number;

    if (existingPeriod) {
      if (existingPeriod.week_end !== week_end) {
        return new Response(
          JSON.stringify({
            error: `A pay period starting ${week_start} already exists with a different end date (${existingPeriod.week_end}). Period boundaries can't be changed after creation.`,
          }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (existingPeriod.locked_at) {
        return new Response(
          JSON.stringify({ error: "This pay period is already locked and can't accept new submissions.", locked: true }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      payPeriodId = existingPeriod.id;
    } else {
      const { data: created, error: createErr } = await supabase
        .from("pay_periods")
        .insert({ business_id: businessId, week_start, week_end })
        .select("id")
        .maybeSingle();

      if (createErr || !created) {
        return new Response(JSON.stringify({ error: "Failed to create pay period: " + (createErr?.message ?? "unknown error") }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      payPeriodId = created.id;
    }

    // ── Upsert the employee's status row for this period ────────────
    const { data: existingStatus } = await supabase
      .from("employee_pay_period_status")
      .select("id, status")
      .eq("pay_period_id", payPeriodId)
      .eq("user_id", targetUserId)
      .maybeSingle();

    if (existingStatus?.status === "submitted") {
      return new Response(JSON.stringify({ error: "This timesheet has already been submitted and is awaiting review." }), {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (existingStatus?.status === "approved") {
      return new Response(JSON.stringify({ error: "This timesheet has already been approved." }), {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const fromStatus = existingStatus?.status ?? null;
    const nowIso = new Date().toISOString();

    let statusRow;
    if (existingStatus) {
      const { data: updated, error: updateErr } = await supabase
        .from("employee_pay_period_status")
        .update({
          status: "submitted",
          submitted_at: nowIso,
          rejected_at: null,
          rejected_by: null,
          rejection_reason: null,
        })
        .eq("id", existingStatus.id)
        .select()
        .maybeSingle();
      if (updateErr) {
        return new Response(JSON.stringify({ error: "Failed to submit timesheet: " + updateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      statusRow = updated;
    } else {
      const { data: inserted, error: insertErr } = await supabase
        .from("employee_pay_period_status")
        .insert({
          business_id: businessId,
          pay_period_id: payPeriodId,
          user_id: targetUserId,
          status: "submitted",
          submitted_at: nowIso,
        })
        .select()
        .maybeSingle();
      if (insertErr) {
        return new Response(JSON.stringify({ error: "Failed to submit timesheet: " + insertErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      statusRow = inserted;
    }

    // changed_by has an FK to profiles(user_id) — superuser has no
    // profiles row, so fall back to null for a superuser-driven submit.
    const changedByUserId = profile?.business_id ? callerUserId : null;

    await supabase.from("pay_period_status_history").insert({
      business_id: businessId,
      pay_period_id: payPeriodId,
      user_id: targetUserId,
      from_status: fromStatus,
      to_status: "submitted",
      changed_by: changedByUserId,
    });

    // ── Notify the owner (best-effort — never fails the submission) ──
    try {
      const { data: business } = await supabase
        .from("businesses")
        .select("business_name, owner_email, business_email, admin_email")
        .eq("id", businessId)
        .maybeSingle();

      const ownerEmail = business?.owner_email || business?.business_email || business?.admin_email;
      if (ownerEmail && MAILGUN_API_KEY) {
        const businessName = business?.business_name || "your business";
        const employeeName = targetProfile.full_name || "An employee";
        const lines = [
          `${employeeName} just submitted their timesheet for review.`,
          "",
          `Period: ${week_start} to ${week_end}`,
          "",
          "Review it in NexaFlow under Timesheets & Payroll.",
          "",
          `— ${businessName}`,
        ];
        const form = new URLSearchParams();
        form.append("from", `${businessName} <no-reply@${MAILGUN_DOMAIN}>`);
        form.append("to", ownerEmail);
        form.append("subject", `🕒 Timesheet Submitted by ${employeeName}`);
        form.append("text", lines.join("\n"));

        await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
          method: "POST",
          headers: {
            "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: form.toString(),
        });
      }
    } catch (notifyErr) {
      console.error("submit-timesheet notify error (non-fatal):", notifyErr);
    }

    return new Response(JSON.stringify({ success: true, status: statusRow }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});