import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// deno-lint-ignore no-explicit-any
function findLockedPeriod(payPeriods: any[], dateOnly: string) {
  return payPeriods.find((p) => p.locked_at && p.week_start <= dateOnly && p.week_end >= dateOnly) ?? null;
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

    let body: Record<string, string> = {};
    try {
      body = await req.json();
    } catch (_) {
      // no body is fine
    }

    const { start_date, end_date, user_id_filter, business_id: requestedBusinessId, group_by } = body;

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("business_id, role, full_name, permissions")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let isOwner: boolean;
    let canManagePayRates: boolean;
    let canManageTimesheets: boolean;
    let canManagePayPeriods: boolean;
    let isSuperuserCaller = false;

    if (profile?.business_id) {
      businessId = profile.business_id;
      const perms = (profile.permissions ?? {}) as Record<string, unknown>;
      isOwner = profile.role === "owner" || profile.role === "admin" || perms.timesheets_full_view === true;
      canManagePayRates = profile.role === "owner" || profile.role === "admin" || perms.manage_pay_rates === true;
      canManageTimesheets = profile.role === "owner" || profile.role === "admin" || perms.manage_timesheets === true;
      canManagePayPeriods = profile.role === "owner" || profile.role === "admin";
    } else {
      // No profile row — check if caller is a verified superuser before
      // trusting any business_id from the request body.
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
      isOwner = true; // superuser sees the full team view
      canManagePayRates = true; // superuser can see pay rates too
      canManageTimesheets = true; // superuser can manage entries too
      canManagePayPeriods = true; // superuser can lock/unlock too
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

    // ── Fetch active entry for the caller ──────────────────────
    const { data: myActiveEntry } = await supabase
      .from("time_entries")
      .select("*")
      .eq("user_id", callerUserId)
      .in("status", ["active", "on_break"])
      .is("deleted_at", null)
      .maybeSingle();

    // ── Fetch all profiles for this business (for name lookup) ────────
    const { data: teamProfiles } = await supabase
      .from("profiles")
      .select("id, user_id, full_name, role, pay_type, hourly_rate, annual_salary")
      .eq("business_id", businessId);

    const profileMap: Record<string, string> = {};
    const profileIdByUserId: Record<string, number> = {};
    const payRateByUserId: Record<string, { pay_type: string; hourly_rate: number | null; annual_salary: number | null }> = {};
    for (const p of (teamProfiles ?? [])) {
      profileMap[p.user_id] = p.full_name ?? "Unknown";
      if (typeof p.id === "number") profileIdByUserId[p.user_id] = p.id;
      payRateByUserId[p.user_id] = {
        pay_type: p.pay_type ?? "hourly",
        hourly_rate: p.hourly_rate ?? null,
        annual_salary: p.annual_salary ?? null,
      };
    }

    // ── Fetch pay period lock state for this business ─────────────────
    let payPeriodsQuery = supabase
      .from("pay_periods")
      .select("id, week_start, week_end, locked_at, locked_by")
      .eq("business_id", businessId);

    if (start_date) payPeriodsQuery = payPeriodsQuery.gte("week_end", start_date);
    if (end_date) payPeriodsQuery = payPeriodsQuery.lte("week_start", end_date);

    const { data: payPeriodsRaw } = await payPeriodsQuery;

    const payPeriods = (payPeriodsRaw ?? []).map((p) => ({
      ...p,
      locked_by_name: p.locked_by ? (profileMap[p.locked_by] ?? null) : null,
    }));

    // ── Build time_entries query ────────────────────────────
    let query = supabase
      .from("time_entries")
      .select("*")
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .order("clocked_in_at", { ascending: false });

    // Non-owners only see their own entries
    if (!isOwner) {
      query = query.eq("user_id", callerUserId);
    } else if (user_id_filter) {
      query = query.eq("user_id", user_id_filter);
    }

    if (start_date) {
      query = query.gte("clocked_in_at", `${start_date}T00:00:00.000Z`);
    }
    if (end_date) {
      query = query.lte("clocked_in_at", `${end_date}T23:59:59.999Z`);
    }

    const { data: entries, error: entriesError } = await query;

    if (entriesError) {
      return new Response(JSON.stringify({ error: "Failed to fetch entries: " + entriesError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Fetch breaks for these entries — TS-05. Used to compute payable
    // minutes (duration minus unpaid break time) and to show a break
    // column per shift. Only ended breaks count; an open break (still on
    // break right now) contributes 0 until it's closed.
    const entryIds = (entries ?? []).map((e) => e.id);
    const breaksByEntryId: Record<number, {
      break_minutes: number;
      unpaid_break_minutes: number;
      paid_break_minutes: number;
      list: Array<{ id: number; started_at: string; ended_at: string | null; is_paid: boolean; minutes: number | null }>;
    }> = {};
    if (entryIds.length > 0) {
      const { data: breaks } = await supabase
        .from("time_entry_breaks")
        .select("id, time_entry_id, started_at, ended_at, is_paid")
        .in("time_entry_id", entryIds)
        .is("deleted_at", null)
        .order("started_at", { ascending: true });

      for (const b of (breaks ?? [])) {
        if (!breaksByEntryId[b.time_entry_id]) {
          breaksByEntryId[b.time_entry_id] = { break_minutes: 0, unpaid_break_minutes: 0, paid_break_minutes: 0, list: [] };
        }
        const mins = b.ended_at
          ? Math.round((new Date(b.ended_at).getTime() - new Date(b.started_at).getTime()) / 60000)
          : null;
        if (mins != null) {
          breaksByEntryId[b.time_entry_id].break_minutes += mins;
          if (b.is_paid) {
            breaksByEntryId[b.time_entry_id].paid_break_minutes += mins;
          } else {
            breaksByEntryId[b.time_entry_id].unpaid_break_minutes += mins;
          }
        }
        breaksByEntryId[b.time_entry_id].list.push({
          id: b.id,
          started_at: b.started_at,
          ended_at: b.ended_at,
          is_paid: b.is_paid === true,
          minutes: mins,
        });
      }
    }

    // ── Fetch appointment details for entries that have one ──────────
    const appointmentIds = [...new Set(
      (entries ?? []).map((e) => e.appointment_id).filter((id) => id != null)
    )];

    const appointmentMap: Record<number, { appointment_type: string; lead_name: string | null; location: string | null }> = {};
    if (appointmentIds.length > 0) {
      const { data: appts } = await supabase
        .from("appointments")
        .select("id, appointment_type, lead_name, location")
        .in("id", appointmentIds);

      for (const a of (appts ?? [])) {
        appointmentMap[a.id] = {
          appointment_type: a.appointment_type,
          lead_name: a.lead_name,
          location: a.location,
        };
      }
    }

    // ── Fetch job-site check-ins for the profiles/date range covered by
    // these entries. appointments.checked_in_at is the real history (one
    // row per visited stop); team_locations only ever holds the latest
    // ping, so it can't answer "what stops did this shift cover."
    const involvedProfileIds = [...new Set(
      (entries ?? []).map((e) => profileIdByUserId[e.user_id]).filter((id) => id != null)
    )];

    let checkInsByProfileId: Record<number, Array<{ appointment_id: number; appointment_name: string; location: string | null; checked_in_at: string }>> = {};
    if (involvedProfileIds.length > 0) {
      const { data: checkedInAppts } = await supabase
        .from("appointments")
        .select("id, appointment_name, location, checked_in_at, assigned_to_profile_id")
        .eq("business_id", businessId)
        .in("assigned_to_profile_id", involvedProfileIds)
        .not("checked_in_at", "is", null);

      for (const a of (checkedInAppts ?? [])) {
        const pid = a.assigned_to_profile_id;
        if (!checkInsByProfileId[pid]) checkInsByProfileId[pid] = [];
        checkInsByProfileId[pid].push({
          appointment_id: a.id,
          appointment_name: a.appointment_name,
          location: a.location,
          checked_in_at: a.checked_in_at,
        });
      }
    }

    // ── Enrich entries with full_name, appointment info, and any
    // check-ins that fall within this shift's clock-in/out window ──────
    const enriched = (entries ?? []).map((e) => {
      const profileId = profileIdByUserId[e.user_id];
      const shiftStart = new Date(e.clocked_in_at).getTime();
      const shiftEnd = e.clocked_out_at ? new Date(e.clocked_out_at).getTime() : Date.now();
      const allCheckIns = profileId != null ? (checkInsByProfileId[profileId] ?? []) : [];
      const shiftCheckIns = allCheckIns
        .filter((c) => {
          const t = new Date(c.checked_in_at).getTime();
          return t >= shiftStart && t <= shiftEnd;
        })
        .sort((a, b) => new Date(a.checked_in_at).getTime() - new Date(b.checked_in_at).getTime());

      const breakInfo = breaksByEntryId[e.id] ?? { break_minutes: 0, unpaid_break_minutes: 0, paid_break_minutes: 0, list: [] };
      const payableMinutes = e.duration_minutes != null
        ? Math.max(0, e.duration_minutes - breakInfo.unpaid_break_minutes)
        : null;

      return {
        ...e,
        full_name: profileMap[e.user_id] ?? "Unknown",
        edited_by_name: e.edited_by ? (profileMap[e.edited_by] ?? null) : null,
        appointment_info: e.appointment_id ? (appointmentMap[e.appointment_id] ?? null) : null,
        shift_check_ins: shiftCheckIns,
        break_minutes: breakInfo.break_minutes,
        unpaid_break_minutes: breakInfo.unpaid_break_minutes,
        paid_break_minutes: breakInfo.paid_break_minutes,
        payable_minutes: payableMinutes,
        breaks: canManagePayRates ? breakInfo.list : [],
      };
    });

    // ── Compute per-member totals (owner view) ────────────────
    const totals: Record<string, {
      user_id: string;
      full_name: string;
      total_minutes: number;
      total_break_minutes: number;
      entry_count: number;
      pay_type?: string;
      hourly_rate?: number | null;
      annual_salary?: number | null;
    }> = {};
    if (isOwner) {
      for (const e of enriched) {
        if (!totals[e.user_id]) {
          totals[e.user_id] = {
            user_id: e.user_id,
            full_name: e.full_name,
            total_minutes: 0,
            total_break_minutes: 0,
            entry_count: 0,
          };
          if (canManagePayRates) {
            const payInfo = payRateByUserId[e.user_id];
            totals[e.user_id].pay_type = payInfo?.pay_type ?? "hourly";
            totals[e.user_id].hourly_rate = payInfo?.hourly_rate ?? null;
            totals[e.user_id].annual_salary = payInfo?.annual_salary ?? null;
          }
        }
        // total_minutes is payable time (duration minus unpaid break time),
        // not raw clock-in-to-clock-out time. Paid breaks stay included.
        totals[e.user_id].total_minutes += (e.payable_minutes ?? e.duration_minutes ?? 0);
        totals[e.user_id].total_break_minutes += (e.break_minutes ?? 0);
        totals[e.user_id].entry_count += 1;
      }
    }

    // ── Flag stale entries (active for 14+ hours) and locked-week entries ──
    const now = new Date();
    const enrichedWithStale = enriched.map((e) => {
      const dateOnly = String(e.clocked_in_at).substring(0, 10);
      const isWeekLocked = findLockedPeriod(payPeriods, dateOnly) != null;
      if (e.status !== "active") return { ...e, is_week_locked: isWeekLocked };
      const clockedIn = new Date(e.clocked_in_at);
      const hoursElapsed = (now.getTime() - clockedIn.getTime()) / (1000 * 60 * 60);
      return { ...e, is_stale_display: hoursElapsed >= 14, is_week_locked: isWeekLocked };
    });

    // ── Optional per-day aggregation for the Month Calendar sub-view ──
    let dailyTotals: Array<{ date: string; total_minutes: number; total_break_minutes: number; entry_count: number }> = [];
    if (group_by === "day") {
      const dayMap: Record<string, { total_minutes: number; total_break_minutes: number; entry_count: number }> = {};
      for (const e of enrichedWithStale) {
        const dateKey = String(e.clocked_in_at).substring(0, 10);
        if (!dayMap[dateKey]) dayMap[dateKey] = { total_minutes: 0, total_break_minutes: 0, entry_count: 0 };
        dayMap[dateKey].total_minutes += (e.payable_minutes ?? e.duration_minutes ?? 0);
        dayMap[dateKey].total_break_minutes += (e.break_minutes ?? 0);
        dayMap[dateKey].entry_count += 1;
      }
      dailyTotals = Object.entries(dayMap).map(([date, v]) => ({ date, ...v }));
    }

    const teamProfilesForResponse = (teamProfiles ?? []).map((p) => {
      if (canManagePayRates) return p;
      const { pay_type: _pt, hourly_rate: _hr, annual_salary: _as, ...rest } = p;
      return rest;
    });

    return new Response(
      JSON.stringify({
        success: true,
        is_owner: isOwner,
        can_view_pay_rates: isOwner ? canManagePayRates : false,
        can_manage_timesheets: canManageTimesheets,
        my_active_entry: myActiveEntry ?? null,
        entries: enrichedWithStale,
        totals: isOwner ? Object.values(totals) : [],
        daily_totals: dailyTotals,
        team_profiles: isOwner ? teamProfilesForResponse : [],
        can_manage_pay_periods: canManagePayPeriods,
        pay_periods: payPeriods,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});