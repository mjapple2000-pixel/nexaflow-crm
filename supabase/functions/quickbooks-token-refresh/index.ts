import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const QB_CLIENT_ID = Deno.env.get("QUICKBOOKS_CLIENT_ID")!;
const QB_CLIENT_SECRET = Deno.env.get("QUICKBOOKS_CLIENT_SECRET")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Runs daily via pg_cron. This exists alongside (not instead of) the
// just-in-time refresh already inside quickbooks-sync-invoice/-contact —
// those only touch a connection's tokens when a sync actually fires. A
// business with no invoice/contact activity for a stretch would never
// trigger that path, and QuickBooks silently expires a refresh token
// after ~100 days of it going untouched. This job proactively refreshes
// any connection nearing that risk so a dormant connection never quietly
// requires a full reconnect.
Deno.serve(async (req) => {
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    // Refresh anything expiring within 24h (covers access-token freshness)
    // as well as anything not refreshed in a while, as a dormancy guard.
    const soon = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

    const { data: connections, error: connErr } = await supabase
      .from("accounting_connections")
      .select("id, business_id, provider, access_token_secret_id, refresh_token_secret_id, token_expires_at")
      .eq("provider", "quickbooks")
      .eq("connection_status", "connected")
      .is("deleted_at", null)
      .lte("token_expires_at", soon);

    if (connErr) {
      return new Response(JSON.stringify({ error: connErr.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: Array<{ business_id: number; status: string; error?: string }> = [];

    for (const conn of connections ?? []) {
      const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", {
        p_id: conn.refresh_token_secret_id,
      });

      if (!refreshToken) {
        results.push({ business_id: conn.business_id, status: "failed", error: "Missing stored refresh token" });
        continue;
      }

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
        const errText = await tokenResp.text();
        console.error(`QB token refresh failed for business ${conn.business_id}:`, errText);
        await supabase
          .from("accounting_connections")
          .update({ connection_status: "error", updated_at: new Date().toISOString() })
          .eq("id", conn.id);
        results.push({ business_id: conn.business_id, status: "failed", error: errText });
        continue;
      }

      const tokens = await tokenResp.json();
      await supabase.rpc("qb_vault_update_secret", { p_id: conn.access_token_secret_id, p_secret: tokens.access_token });
      await supabase.rpc("qb_vault_update_secret", { p_id: conn.refresh_token_secret_id, p_secret: tokens.refresh_token });

      const newExpiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();
      await supabase
        .from("accounting_connections")
        .update({ token_expires_at: newExpiresAt, updated_at: new Date().toISOString() })
        .eq("id", conn.id);

      results.push({ business_id: conn.business_id, status: "success" });
    }

    return new Response(JSON.stringify({ success: true, checked: connections?.length ?? 0, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("quickbooks-token-refresh error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
