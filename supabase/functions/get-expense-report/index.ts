import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SERVICE_ROLE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: { user }, error: userErr } = await supabase
      .auth.getUser(authHeader.replace("Bearer ", ""));
    if (userErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const { data: profile, error: profErr } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", user.id)
      .maybeSingle();

    const url = new URL(req.url);

    let businessId: number;
    if (profErr || !profile) {
      const businessIdParam = url.searchParams.get("business_id");
      if (user.email === "vantagecaretech@gmail.com" && businessIdParam) {
        businessId = parseInt(businessIdParam);
      } else {
        return new Response(JSON.stringify({ error: "Profile not found" }), { status: 403, headers: corsHeaders });
      }
    } else {
      businessId = profile.business_id;
    }

    // Same plan gate as the rest of Job Costing — expense tracking is part
    // of that Growth+ feature bundle, not a separate gate.
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

    const dateRangeDays = parseInt(url.searchParams.get("date_range_days") ?? "30");
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - dateRangeDays);
    const cutoffIso = cutoff.toISOString();

    const { data: expenses, error: expErr } = await supabase
      .from("job_expenses")
      .select("id, appointment_id, deal_id, category_id, amount_cents, billable, logged_by_profile_id, logged_at, expense_categories(name)")
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .gte("logged_at", cutoffIso);
    if (expErr) throw expErr;

    const rows = expenses ?? [];

    // ── By Category ──────────────────────────────────────────────
    const byCategory: Record<string, { category: string; count: number; total_cents: number }> = {};
    for (const r of rows) {
      const cat = (r.expense_categories as { name?: string } | null)?.name ?? "Uncategorized";
      if (!byCategory[cat]) byCategory[cat] = { category: cat, count: 0, total_cents: 0 };
      byCategory[cat].count += 1;
      byCategory[cat].total_cents += r.amount_cents ?? 0;
    }
    const expensesByCategory = Object.values(byCategory).sort((a, b) => b.total_cents - a.total_cents);

    // ── By Team Member ───────────────────────────────────────────
    const profileIds = [...new Set(rows.map((r) => r.logged_by_profile_id).filter((v) => v != null))] as number[];
    let profileNameMap: Record<number, string> = {};
    if (profileIds.length > 0) {
      const { data: profiles } = await supabase
        .from("profiles")
        .select("id, full_name")
        .in("id", profileIds);
      for (const p of profiles ?? []) profileNameMap[p.id] = p.full_name ?? "Unknown";
    }
    const byMember: Record<string, { member: string; count: number; total_cents: number }> = {};
    for (const r of rows) {
      const key = r.logged_by_profile_id != null ? (profileNameMap[r.logged_by_profile_id] ?? "Unknown") : "Unassigned";
      if (!byMember[key]) byMember[key] = { member: key, count: 0, total_cents: 0 };
      byMember[key].count += 1;
      byMember[key].total_cents += r.amount_cents ?? 0;
    }
    const expensesByMember = Object.values(byMember).sort((a, b) => b.total_cents - a.total_cents);

    // ── By Job ────────────────────────────────────────────────────
    const apptIds = [...new Set(rows.map((r) => r.appointment_id).filter((v) => v != null))] as number[];
    const dealIds = [...new Set(rows.map((r) => r.deal_id).filter((v) => v != null))] as number[];
    let apptNameMap: Record<number, string> = {};
    let dealNameMap: Record<number, string> = {};
    if (apptIds.length > 0) {
      const { data: appts } = await supabase
        .from("appointments")
        .select("id, appointment_name")
        .in("id", apptIds)
        .eq("business_id", businessId);
      for (const a of appts ?? []) apptNameMap[a.id] = a.appointment_name ?? "Untitled Job";
    }
    if (dealIds.length > 0) {
      const { data: deals } = await supabase
        .from("deals")
        .select("id, deal_name")
        .in("id", dealIds)
        .eq("business_id", businessId);
      for (const d of deals ?? []) dealNameMap[d.id] = d.deal_name ?? "Untitled Deal";
    }
    const byJob: Record<string, { job_name: string; count: number; total_cents: number }> = {};
    for (const r of rows) {
      const key = r.appointment_id != null
        ? `appt:${r.appointment_id}`
        : r.deal_id != null ? `deal:${r.deal_id}` : "none";
      const name = r.appointment_id != null
        ? (apptNameMap[r.appointment_id] ?? "Untitled Job")
        : r.deal_id != null ? (dealNameMap[r.deal_id] ?? "Untitled Deal") : "Unlinked";
      if (!byJob[key]) byJob[key] = { job_name: name, count: 0, total_cents: 0 };
      byJob[key].count += 1;
      byJob[key].total_cents += r.amount_cents ?? 0;
    }
    const expensesByJob = Object.values(byJob).sort((a, b) => b.total_cents - a.total_cents);

    const totalCents = rows.reduce((s, r) => s + (r.amount_cents ?? 0), 0);
    const billableCents = rows.filter((r) => r.billable !== false).reduce((s, r) => s + (r.amount_cents ?? 0), 0);

    return new Response(JSON.stringify({
      success: true,
      date_range_days: dateRangeDays,
      total_cents: totalCents,
      billable_cents: billableCents,
      expenses_by_job: expensesByJob,
      expenses_by_member: expensesByMember,
      expenses_by_category: expensesByCategory,
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("get-expense-report error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});