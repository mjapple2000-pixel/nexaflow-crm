import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const QB_CLIENT_ID = Deno.env.get("QUICKBOOKS_CLIENT_ID")!;
const QB_CLIENT_SECRET = Deno.env.get("QUICKBOOKS_CLIENT_SECRET")!;
const QB_ENV = Deno.env.get("QUICKBOOKS_ENVIRONMENT") ?? "sandbox";
const QB_API_BASE = QB_ENV === "production"
  ? "https://quickbooks.api.intuit.com"
  : "https://sandbox-quickbooks.api.intuit.com";

const MAX_RETRIES = 3;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

type TokenResult = { accessToken: string; realmId: string } | { error: string };

// Mirrors the same on-demand refresh pattern used in quickbooks-sync-invoice
// (kept inline here rather than a shared import, matching this codebase's
// existing convention of self-contained edge functions).
async function getValidAccessToken(businessId: number): Promise<TokenResult> {
  const { data: conn, error: connErr } = await supabase
    .from("accounting_connections")
    .select("access_token_secret_id, refresh_token_secret_id, token_expires_at, qb_realm_id")
    .eq("business_id", businessId)
    .eq("provider", "quickbooks")
    .eq("connection_status", "connected")
    .is("deleted_at", null)
    .maybeSingle();

  if (connErr || !conn) return { error: "No active QuickBooks connection for this business" };

  const expiresAt = new Date(conn.token_expires_at).getTime();
  const needsRefresh = expiresAt - Date.now() < 5 * 60 * 1000;

  if (!needsRefresh) {
    const { data: accessToken } = await supabase.rpc("qb_vault_read_secret", {
      p_id: conn.access_token_secret_id,
    });
    if (!accessToken) return { error: "Failed to read stored access token" };
    return { accessToken, realmId: conn.qb_realm_id };
  }

  const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", {
    p_id: conn.refresh_token_secret_id,
  });
  if (!refreshToken) return { error: "Failed to read stored refresh token" };

  const tokenResp = await fetch("https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer", {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${QB_CLIENT_ID}:${QB_CLIENT_SECRET}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "application/json",
    },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken }),
  });

  if (!tokenResp.ok) {
    console.error("QB token refresh failed:", await tokenResp.text());
    await supabase
      .from("accounting_connections")
      .update({ connection_status: "error" })
      .eq("business_id", businessId)
      .eq("provider", "quickbooks");
    return { error: "Token refresh failed — connection marked as needing reconnect" };
  }

  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", { p_id: conn.access_token_secret_id, p_secret: tokens.access_token });
  await supabase.rpc("qb_vault_update_secret", { p_id: conn.refresh_token_secret_id, p_secret: tokens.refresh_token });

  const newExpiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();
  await supabase
    .from("accounting_connections")
    .update({ token_expires_at: newExpiresAt, updated_at: new Date().toISOString() })
    .eq("business_id", businessId)
    .eq("provider", "quickbooks");

  return { accessToken: tokens.access_token, realmId: conn.qb_realm_id };
}

async function logSync(params: {
  businessId: number;
  localId: string;
  qbId: string | null;
  status: "success" | "failed";
  errorMessage?: string;
  retryCount: number;
}) {
  await supabase.from("accounting_sync_log").insert({
    business_id: params.businessId,
    entity_type: "time_activity",
    local_id: params.localId,
    qb_id: params.qbId,
    direction: "to_qb",
    status: params.status,
    error_message: params.errorMessage ?? null,
    retry_count: params.retryCount,
    synced_at: new Date().toISOString(),
  }).then(() => {}, (e) => console.error("Sync log write failed:", e));
}

Deno.serve(async (req) => {
  try {
    const { pay_period_id, is_manual_retry } = await req.json();
    if (!pay_period_id) {
      return new Response(JSON.stringify({ error: "pay_period_id required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: payPeriod, error: ppErr } = await supabase
      .from("pay_periods")
      .select("id, business_id, week_start, week_end, locked_at, qbo_sync_attempts")
      .eq("id", pay_period_id)
      .maybeSingle();

    if (ppErr || !payPeriod) {
      return new Response(JSON.stringify({ error: "Pay period not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }

    // ── Auth: either the shared cron secret (DB trigger on lock, or the
    // 15-min retry sweep) or a real owner/admin JWT for the business that
    // owns this pay period (the UI's manual "Retry Sync" button). The
    // client never holds the cron secret.
    const providedSecret = req.headers.get("x-cron-secret") ?? "";
    const isCronAuthorized = !!CRON_SECRET && providedSecret === CRON_SECRET;

    if (!isCronAuthorized) {
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        });
      }
      const supabaseAuth = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: userData, error: userError } = await supabaseAuth.auth.getUser();
      if (userError || !userData?.user) {
        return new Response(JSON.stringify({ error: "Invalid or expired session" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        });
      }

      const { data: callerProfile } = await supabase
        .from("profiles")
        .select("business_id, role")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      const { data: isSuperuser } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      const isOwnerOrAdmin = callerProfile?.role === "owner" || callerProfile?.role === "admin";
      const businessMatches = callerProfile?.business_id === payPeriod.business_id;

      if (!isSuperuser && !(isOwnerOrAdmin && businessMatches)) {
        return new Response(JSON.stringify({ error: "Not authorized to manage this pay period's sync" }), {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    if (!payPeriod.locked_at) {
      return new Response(JSON.stringify({ skipped: true, reason: "Pay period is not locked" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // ── Retry budget: one counter per pay period, incremented once per
    // whole sync attempt (not per team member).
    // A manual click from the UI is an explicit request to try again —
    // give it a fresh budget rather than leaving the owner stuck with no
    // way to act once the automatic sweep has exhausted its retries.
    const attemptNumber = is_manual_retry === true ? 0 : (payPeriod.qbo_sync_attempts ?? 0);

    if (attemptNumber >= MAX_RETRIES) {
      return new Response(JSON.stringify({ skipped: true, reason: "Max retry attempts reached — manual retry required" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    await supabase
      .from("pay_periods")
      .update({ qbo_sync_status: "syncing", qbo_sync_attempts: attemptNumber + 1 })
      .eq("id", payPeriod.id);

    // ── Plan gate: defense-in-depth even though the DB trigger should
    // already prevent this call from firing for non-entitled businesses.
    const { data: hasFeature } = await supabase.rpc("check_plan_feature", {
      p_business_id: payPeriod.business_id,
      p_feature: "quickbooks_payroll_sync",
    });
    if (!hasFeature) {
      await supabase.from("pay_periods").update({ qbo_sync_status: "failed" }).eq("id", payPeriod.id);
      await logSync({
        businessId: payPeriod.business_id,
        localId: `${payPeriod.id}:plan_gate`,
        qbId: null,
        status: "failed",
        errorMessage: "Business is not entitled to QuickBooks payroll sync on its current plan",
        retryCount: 0,
      });
      return new Response(JSON.stringify({ error: "upgrade_required" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const tokenResult = await getValidAccessToken(payPeriod.business_id);
    if ("error" in tokenResult) {
      await supabase.from("pay_periods").update({ qbo_sync_status: "failed" }).eq("id", payPeriod.id);
      await logSync({
        businessId: payPeriod.business_id,
        localId: `${payPeriod.id}:connection`,
        qbId: null,
        status: "failed",
        errorMessage: tokenResult.error,
        retryCount: attemptNumber,
      });
      return new Response(JSON.stringify({ error: tokenResult.error }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    const { accessToken, realmId } = tokenResult;
    const qbHeaders = {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "Accept": "application/json",
    };

    // ── Pull locked hours for this period (payable minutes = duration
    // minus unpaid break time, same rule get-timesheets/recomputeCurrentPayRate
    // use elsewhere in this codebase). Grouped per team member.
    const { data: entries, error: entriesErr } = await supabase
      .from("time_entries")
      .select("id, user_id, duration_minutes, clocked_in_at")
      .eq("business_id", payPeriod.business_id)
      .gte("clocked_in_at", `${payPeriod.week_start}T00:00:00.000Z`)
      .lte("clocked_in_at", `${payPeriod.week_end}T23:59:59.999Z`)
      .is("deleted_at", null);

    if (entriesErr) {
      await supabase.from("pay_periods").update({ qbo_sync_status: "failed" }).eq("id", payPeriod.id);
      await logSync({
        businessId: payPeriod.business_id,
        localId: `${payPeriod.id}:entries`,
        qbId: null,
        status: "failed",
        errorMessage: entriesErr.message,
        retryCount: attemptNumber,
      });
      return new Response(JSON.stringify({ error: entriesErr.message }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const entryIds = (entries ?? []).map((e) => e.id);
    const unpaidBreakMinutesByEntry: Record<number, number> = {};
    if (entryIds.length > 0) {
      const { data: breaks } = await supabase
        .from("time_entry_breaks")
        .select("time_entry_id, started_at, ended_at, is_paid")
        .in("time_entry_id", entryIds)
        .eq("is_paid", false)
        .is("deleted_at", null);
      for (const b of breaks ?? []) {
        if (!b.ended_at) continue;
        const mins = Math.round((new Date(b.ended_at).getTime() - new Date(b.started_at).getTime()) / 60000);
        unpaidBreakMinutesByEntry[b.time_entry_id] = (unpaidBreakMinutesByEntry[b.time_entry_id] ?? 0) + mins;
      }
    }

    const payableMinutesByUserId: Record<string, number> = {};
    for (const e of entries ?? []) {
      const unpaid = unpaidBreakMinutesByEntry[e.id] ?? 0;
      const payable = Math.max(0, (e.duration_minutes ?? 0) - unpaid);
      payableMinutesByUserId[e.user_id] = (payableMinutesByUserId[e.user_id] ?? 0) + payable;
    }

    const userIds = Object.keys(payableMinutesByUserId).filter((uid) => payableMinutesByUserId[uid] > 0);

    if (userIds.length === 0) {
      await supabase
        .from("pay_periods")
        .update({ qbo_sync_status: "success", qbo_last_synced_at: new Date().toISOString() })
        .eq("id", payPeriod.id);
      return new Response(JSON.stringify({ success: true, synced: 0, reason: "No payable hours in this period" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: profiles } = await supabase
      .from("profiles")
      .select("id, user_id, full_name")
      .eq("business_id", payPeriod.business_id)
      .in("user_id", userIds);

    const profileByUserId: Record<string, { id: number; full_name: string }> = {};
    for (const p of profiles ?? []) {
      profileByUserId[p.user_id] = { id: p.id, full_name: p.full_name ?? "Unknown" };
    }

    const { data: mappings } = await supabase
      .from("team_member_provider_mappings")
      .select("profile_id, external_employee_id")
      .eq("business_id", payPeriod.business_id)
      .eq("provider", "quickbooks")
      .is("deleted_at", null);

    const mappingByProfileId: Record<number, string> = {};
    for (const m of mappings ?? []) {
      mappingByProfileId[m.profile_id] = m.external_employee_id;
    }

    let anyFailed = false;
    let syncedCount = 0;

    for (const userId of userIds) {
      const profile = profileByUserId[userId];
      if (!profile) continue;

      const localId = `${payPeriod.id}:${profile.id}`;
      const externalEmployeeId = mappingByProfileId[profile.id];

      if (!externalEmployeeId) {
        anyFailed = true;
        await logSync({
          businessId: payPeriod.business_id,
          localId,
          qbId: null,
          status: "failed",
          errorMessage: `${profile.full_name} is not mapped to a QuickBooks employee — set this in Team Member Mapping`,
          retryCount: attemptNumber,
        });
        continue;
      }

      const totalMinutes = payableMinutesByUserId[userId];
      const hours = Math.floor(totalMinutes / 60);
      const minutes = totalMinutes % 60;

      // Existing successful sync for this member+period, if any — update
      // that Time Activity in QuickBooks instead of creating a duplicate
      // on retry or on a second lock/unlock cycle.
      const { data: existingLog } = await supabase
        .from("accounting_sync_log")
        .select("qb_id")
        .eq("business_id", payPeriod.business_id)
        .eq("entity_type", "time_activity")
        .eq("local_id", localId)
        .eq("status", "success")
        .order("synced_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      const payload: Record<string, unknown> = {
        NameOf: "Employee",
        EmployeeRef: { value: externalEmployeeId },
        TxnDate: payPeriod.week_end,
        Hours: hours,
        Minutes: minutes,
        Description: `NexaFlow pay period ${payPeriod.week_start} to ${payPeriod.week_end}`,
      };

      let qbTimeActivityId: string | null = null;
      let errorMessage: string | null = null;

      if (existingLog?.qb_id) {
        const getResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/timeactivity/${existingLog.qb_id}`, {
          headers: qbHeaders,
        });
        if (getResp.ok) {
          const current = await getResp.json();
          const updateResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/timeactivity`, {
            method: "POST",
            headers: qbHeaders,
            body: JSON.stringify({ ...payload, Id: existingLog.qb_id, SyncToken: current.TimeActivity?.SyncToken }),
          });
          if (updateResp.ok) {
            const updated = await updateResp.json();
            qbTimeActivityId = updated.TimeActivity?.Id ?? existingLog.qb_id;
          } else {
            errorMessage = await updateResp.text();
          }
        } else {
          errorMessage = await getResp.text();
        }
      } else {
        const createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/timeactivity`, {
          method: "POST",
          headers: qbHeaders,
          body: JSON.stringify(payload),
        });
        if (createResp.ok) {
          const created = await createResp.json();
          qbTimeActivityId = created.TimeActivity?.Id ?? null;
        } else {
          errorMessage = await createResp.text();
        }
      }

      if (qbTimeActivityId) {
        syncedCount++;
        await logSync({
          businessId: payPeriod.business_id,
          localId,
          qbId: qbTimeActivityId,
          status: "success",
          retryCount: attemptNumber,
        });
      } else {
        anyFailed = true;
        await logSync({
          businessId: payPeriod.business_id,
          localId,
          qbId: existingLog?.qb_id ?? null,
          status: "failed",
          errorMessage: errorMessage ?? "Unknown error",
          retryCount: attemptNumber,
        });
      }
    }

    await supabase
      .from("pay_periods")
      .update({
        qbo_sync_status: anyFailed ? "failed" : "success",
        qbo_last_synced_at: new Date().toISOString(),
      })
      .eq("id", payPeriod.id);

    return new Response(JSON.stringify({ success: !anyFailed, synced: syncedCount, total: userIds.length }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("quickbooks-sync-hours error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
