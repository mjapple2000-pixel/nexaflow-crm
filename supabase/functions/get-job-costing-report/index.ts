import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // Resolve business_id from JWT — never trust client
    const { data: { user }, error: userErr } = await supabase
      .auth.getUser(authHeader.replace("Bearer ", ""));
    if (userErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const { data: profile, error: profErr } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", user.id)
      .maybeSingle();
    if (profErr || !profile) return new Response(JSON.stringify({ error: "Profile not found" }), { status: 403, headers: corsHeaders });

    const businessId: number = profile.business_id;

    // Plan gate
    const { data: allowed, error: gateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "job_costing" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "Job Costing is available on the Growth plan and above.",
        upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
      }), { status: 403, headers: corsHeaders });
    }

    const url = new URL(req.url);
    const dateRangeDays = parseInt(url.searchParams.get("date_range_days") ?? "30");
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - dateRangeDays);
    const cutoffIso = cutoff.toISOString();

    // Fetch all snapshots for this business within date range
    const { data: snapshots, error: snapErr } = await supabase
      .from("job_revenue_snapshots")
      .select("*")
      .eq("business_id", businessId)
      .gte("snapshotted_at", cutoffIso);
    if (snapErr) throw snapErr;

    const rows = snapshots ?? [];

    // ── Card 1: Profitability by Job Type ─────────────────────────────────
    const byJobType: Record<string, {
      job_type: string;
      count: number;
      total_revenue: number;
      total_expenses: number;
      total_profit: number;
    }> = {};

    for (const row of rows) {
      const key = row.job_type ?? "Uncategorized";
      if (!byJobType[key]) {
        byJobType[key] = { job_type: key, count: 0, total_revenue: 0, total_expenses: 0, total_profit: 0 };
      }
      byJobType[key].count += 1;
      byJobType[key].total_revenue += row.total_revenue_cents ?? 0;
      byJobType[key].total_expenses += row.total_expenses_cents ?? 0;
      byJobType[key].total_profit += row.gross_profit_cents ?? 0;
    }

    const profitByJobType = Object.values(byJobType).map((g) => ({
      job_type: g.job_type,
      jobs_count: g.count,
      avg_revenue_cents: g.count > 0 ? Math.round(g.total_revenue / g.count) : 0,
      avg_expenses_cents: g.count > 0 ? Math.round(g.total_expenses / g.count) : 0,
      avg_profit_cents: g.count > 0 ? Math.round(g.total_profit / g.count) : 0,
      avg_margin_pct: g.total_revenue > 0
        ? Math.round((g.total_profit / g.total_revenue) * 10000) / 100
        : null,
    })).sort((a, b) => b.avg_profit_cents - a.avg_profit_cents);

    // ── Card 2: Profitability by Calendar ─────────────────────────────────
    // Pull appointment calendar_id for each snapshot that has an appointment_id
    const apptIds = rows
      .filter((r) => r.appointment_id != null)
      .map((r) => r.appointment_id as number);

    let calendarMap: Record<number, string> = {};
    if (apptIds.length > 0) {
      const { data: appts } = await supabase
        .from("appointments")
        .select("id, calendar_id, calendars(name)")
        .in("id", apptIds)
        .eq("business_id", businessId);

      for (const a of appts ?? []) {
        const calName = (a.calendars as { name?: string } | null)?.name ?? `Calendar ${a.calendar_id}`;
        calendarMap[a.id] = calName;
      }
    }

    const byCalendar: Record<string, {
      calendar_name: string;
      count: number;
      total_revenue: number;
      total_expenses: number;
      total_profit: number;
    }> = {};

    for (const row of rows) {
      const calName = row.appointment_id
        ? (calendarMap[row.appointment_id] ?? "Unknown Calendar")
        : "No Appointment";
      if (!byCalendar[calName]) {
        byCalendar[calName] = { calendar_name: calName, count: 0, total_revenue: 0, total_expenses: 0, total_profit: 0 };
      }
      byCalendar[calName].count += 1;
      byCalendar[calName].total_revenue += row.total_revenue_cents ?? 0;
      byCalendar[calName].total_expenses += row.total_expenses_cents ?? 0;
      byCalendar[calName].total_profit += row.gross_profit_cents ?? 0;
    }

    const profitByCalendar = Object.values(byCalendar).map((g) => ({
      calendar_name: g.calendar_name,
      jobs_count: g.count,
      total_revenue_cents: g.total_revenue,
      total_expenses_cents: g.total_expenses,
      total_profit_cents: g.total_profit,
    })).sort((a, b) => b.total_profit_cents - a.total_profit_cents);

    // ── Card 3: Top 5 / Bottom 5 by gross profit ──────────────────────────
    // Only include rows where we have profit data
    const withProfit = rows
      .filter((r) => r.gross_profit_cents !== null)
      .sort((a, b) => (b.gross_profit_cents ?? 0) - (a.gross_profit_cents ?? 0));

    // Fetch appointment titles for display
    const allApptIds = withProfit
      .filter((r) => r.appointment_id != null)
      .map((r) => r.appointment_id as number);

    let apptTitleMap: Record<number, { title: string; date: string }> = {};
    if (allApptIds.length > 0) {
      const { data: apptDetails } = await supabase
        .from("appointments")
        .select("id, title, start_time")
        .in("id", allApptIds)
        .eq("business_id", businessId);

      for (const a of apptDetails ?? []) {
        apptTitleMap[a.id] = {
          title: a.title ?? "Untitled Job",
          date: a.start_time ?? "",
        };
      }
    }

    const mapRow = (r: Record<string, unknown>) => ({
      snapshot_id: r.id,
      appointment_id: r.appointment_id,
      deal_id: r.deal_id,
      job_name: r.appointment_id
        ? (apptTitleMap[r.appointment_id as number]?.title ?? "Untitled Job")
        : "Deal Expense",
      job_date: r.appointment_id
        ? (apptTitleMap[r.appointment_id as number]?.date ?? null)
        : null,
      gross_profit_cents: r.gross_profit_cents,
      job_type: r.job_type,
    });

    const top5 = withProfit.slice(0, 5).map(mapRow);
    const bottom5 = [...withProfit].reverse().slice(0, 5).map(mapRow);

    return new Response(JSON.stringify({
      success: true,
      date_range_days: dateRangeDays,
      profit_by_job_type: profitByJobType,
      profit_by_calendar: profitByCalendar,
      top_jobs: top5,
      bottom_jobs: bottom5,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("get-job-costing-report error:", err);
    return new Response(JSON.stringify({ error: err.message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});