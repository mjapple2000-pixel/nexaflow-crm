import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 50;

function uint8ToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function formatDuration(minutes: number): string {
  if (!minutes) return "0m";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m}m`;
  if (m === 0) return `${h}h`;
  return `${h}h ${m}m`;
}

function formatCurrency(amount: number | null): string {
  if (amount == null) return "—";
  return `$${amount.toFixed(2)}`;
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

    const body = await req.json().catch(() => ({}));
    const { start_date, end_date, label, business_id: requestedBusinessId } = body;

    if (!start_date || !end_date) {
      return new Response(JSON.stringify({ error: "start_date and end_date are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id, role, permissions")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let isOwner: boolean;
    let canManagePayRates: boolean;
    let isSuperuserCaller = false;

    if (profile?.business_id) {
      businessId = profile.business_id;
      const perms = (profile.permissions ?? {}) as Record<string, unknown>;
      isOwner = profile.role === "owner" || profile.role === "admin" || perms.timesheets_full_view === true;
      canManagePayRates = profile.role === "owner" || profile.role === "admin" || perms.manage_pay_rates === true;
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
      isOwner = true;
      canManagePayRates = true;
      isSuperuserCaller = true;
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

    if (!isOwner) {
      return new Response(JSON.stringify({ error: "Not authorized to export team totals" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: business } = await supabase
      .from("businesses")
      .select("business_name")
      .eq("id", businessId)
      .maybeSingle();
    const businessName = business?.business_name ?? "NexaFlow";

    const { data: teamProfiles } = await supabase
      .from("profiles")
      .select("user_id, full_name, pay_type, hourly_rate, annual_salary")
      .eq("business_id", businessId);

    const profileByUserId: Record<string, { full_name: string; pay_type: string; hourly_rate: number | null; annual_salary: number | null }> = {};
    for (const p of (teamProfiles ?? [])) {
      profileByUserId[p.user_id] = {
        full_name: p.full_name ?? "Unknown",
        pay_type: p.pay_type ?? "hourly",
        hourly_rate: p.hourly_rate ?? null,
        annual_salary: p.annual_salary ?? null,
      };
    }

    const { data: entries, error: entriesError } = await supabase
      .from("time_entries")
      .select("id, user_id, duration_minutes")
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .gte("clocked_in_at", `${start_date}T00:00:00.000Z`)
      .lte("clocked_in_at", `${end_date}T23:59:59.999Z`);

    if (entriesError) {
      return new Response(JSON.stringify({ error: "Failed to fetch entries: " + entriesError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Break minutes per entry — same payable-minutes logic as
    // get-timesheets. Without this, the PDF would show raw clock time
    // (including breaks) instead of what's actually payable.
    const entryIds = (entries ?? []).map((e) => e.id);
    const breaksByEntryId: Record<number, { break_minutes: number; unpaid_minutes: number }> = {};
    if (entryIds.length > 0) {
      const { data: breaks } = await supabase
        .from("time_entry_breaks")
        .select("time_entry_id, started_at, ended_at, is_paid")
        .in("time_entry_id", entryIds)
        .is("deleted_at", null);

      for (const b of (breaks ?? [])) {
        if (!b.ended_at) continue;
        const mins = Math.round((new Date(b.ended_at).getTime() - new Date(b.started_at).getTime()) / 60000);
        if (!breaksByEntryId[b.time_entry_id]) {
          breaksByEntryId[b.time_entry_id] = { break_minutes: 0, unpaid_minutes: 0 };
        }
        breaksByEntryId[b.time_entry_id].break_minutes += mins;
        if (!b.is_paid) breaksByEntryId[b.time_entry_id].unpaid_minutes += mins;
      }
    }

    const totalsMap: Record<string, { user_id: string; total_minutes: number; total_break_minutes: number; entry_count: number }> = {};
    for (const e of (entries ?? [])) {
      if (!totalsMap[e.user_id]) {
        totalsMap[e.user_id] = { user_id: e.user_id, total_minutes: 0, total_break_minutes: 0, entry_count: 0 };
      }
      const breakInfo = breaksByEntryId[e.id] ?? { break_minutes: 0, unpaid_minutes: 0 };
      const payableMinutes = Math.max(0, (e.duration_minutes ?? 0) - breakInfo.unpaid_minutes);
      totalsMap[e.user_id].total_minutes += payableMinutes;
      totalsMap[e.user_id].total_break_minutes += breakInfo.break_minutes;
      totalsMap[e.user_id].entry_count += 1;
    }
    const totals = Object.values(totalsMap).sort((a, b) => {
      const nameA = profileByUserId[a.user_id]?.full_name ?? "";
      const nameB = profileByUserId[b.user_id]?.full_name ?? "";
      return nameA.localeCompare(nameB);
    });

    // Same pay-period-based salary math as _computePay in timesheets_screen.dart
    const { data: businessConfig } = await supabase
      .from("businesses")
      .select("pay_period_type")
      .eq("id", businessId)
      .maybeSingle();
    const payPeriodType = businessConfig?.pay_period_type ?? "weekly";
    const periodsPerYear = payPeriodType === "biweekly" ? 26 : payPeriodType === "semimonthly" ? 24 : 52;

    function computePay(userId: string, minutes: number): number | null {
      if (!canManagePayRates) return null;
      const info = profileByUserId[userId];
      if (!info) return null;
      if (info.pay_type === "salary") {
        if (info.annual_salary == null) return null;
        return info.annual_salary / periodsPerYear;
      }
      if (info.hourly_rate == null) return null;
      return (minutes / 60) * info.hourly_rate;
    }

    // ── Build the PDF ──────────────────────────────────────────
    const pdfDoc = await PDFDocument.create();
    let page = pdfDoc.addPage([PAGE_W, PAGE_H]);
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const boldFont = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
    let y = PAGE_H - MARGIN;

    page.drawText(businessName, { x: MARGIN, y, size: 16, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    y -= 22;
    page.drawText("Timesheets Export", { x: MARGIN, y, size: 12, font, color: rgb(0.35, 0.35, 0.35) });
    y -= 18;
    if (label) {
      page.drawText(String(label), { x: MARGIN, y, size: 11, font, color: rgb(0.35, 0.35, 0.35) });
      y -= 16;
    }
    page.drawText(`${start_date} to ${end_date}`, { x: MARGIN, y, size: 10, font, color: rgb(0.5, 0.5, 0.5) });
    y -= 28;

    const colX = { name: MARGIN, hours: MARGIN + 170, breaks: MARGIN + 250, entries: MARGIN + 330, pay: MARGIN + 410 };
    const rowHeight = 20;

    function drawHeader() {
      page.drawText("EMPLOYEE", { x: colX.name, y, size: 9, font: boldFont, color: rgb(0.4, 0.4, 0.4) });
      page.drawText("TOTAL HOURS", { x: colX.hours, y, size: 9, font: boldFont, color: rgb(0.4, 0.4, 0.4) });
      page.drawText("BREAK", { x: colX.breaks, y, size: 9, font: boldFont, color: rgb(0.4, 0.4, 0.4) });
      page.drawText("ENTRIES", { x: colX.entries, y, size: 9, font: boldFont, color: rgb(0.4, 0.4, 0.4) });
      if (canManagePayRates) {
        page.drawText("TOTAL PAY", { x: colX.pay, y, size: 9, font: boldFont, color: rgb(0.4, 0.4, 0.4) });
      }
      y -= 8;
      page.drawLine({
        start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y },
        thickness: 0.5, color: rgb(0.8, 0.8, 0.8),
      });
      y -= rowHeight;
    }

    drawHeader();

    let grandMinutes = 0;
    let grandBreakMinutes = 0;
    let grandEntries = 0;
    let grandPay = 0;

    for (const t of totals) {
      if (y < MARGIN + 40) {
        page = pdfDoc.addPage([PAGE_W, PAGE_H]);
        y = PAGE_H - MARGIN;
        drawHeader();
      }
      const name = profileByUserId[t.user_id]?.full_name ?? "Unknown";
      const pay = computePay(t.user_id, t.total_minutes);
      grandMinutes += t.total_minutes;
      grandBreakMinutes += t.total_break_minutes;
      grandEntries += t.entry_count;
      grandPay += pay ?? 0;

      page.drawText(name, { x: colX.name, y, size: 10, font, color: rgb(0.15, 0.15, 0.15) });
      page.drawText(formatDuration(t.total_minutes), { x: colX.hours, y, size: 10, font, color: rgb(0.15, 0.15, 0.15) });
      page.drawText(t.total_break_minutes > 0 ? formatDuration(t.total_break_minutes) : "—", { x: colX.breaks, y, size: 10, font, color: rgb(0.15, 0.15, 0.15) });
      page.drawText(String(t.entry_count), { x: colX.entries, y, size: 10, font, color: rgb(0.15, 0.15, 0.15) });
      if (canManagePayRates) {
        page.drawText(formatCurrency(pay), { x: colX.pay, y, size: 10, font, color: rgb(0.15, 0.15, 0.15) });
      }
      y -= rowHeight;
    }

    y -= 6;
    page.drawLine({
      start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y },
      thickness: 0.5, color: rgb(0.8, 0.8, 0.8),
    });
    y -= rowHeight;

    page.drawText("TOTAL", { x: colX.name, y, size: 10, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    page.drawText(formatDuration(grandMinutes), { x: colX.hours, y, size: 10, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    page.drawText(grandBreakMinutes > 0 ? formatDuration(grandBreakMinutes) : "—", { x: colX.breaks, y, size: 10, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    page.drawText(String(grandEntries), { x: colX.entries, y, size: 10, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    if (canManagePayRates) {
      page.drawText(formatCurrency(grandPay), { x: colX.pay, y, size: 10, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    }

    const pdfBytes = await pdfDoc.save();

    return new Response(
      JSON.stringify({ success: true, pdf_base64: uint8ToBase64(pdfBytes) }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});