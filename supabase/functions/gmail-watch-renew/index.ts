import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Same refresh pattern as gmail-inbound-webhook and quickbooks-token-refresh.
async function getFreshAccessToken(connection: {
  id: number;
  access_token_secret_id: string;
  refresh_token_secret_id: string;
  token_expires_at: string;
}): Promise<string | null> {
  const expiresAt = new Date(connection.token_expires_at).getTime();
  if (expiresAt > Date.now() + 2 * 60 * 1000) {
    const { data: accessToken } = await supabase.rpc("qb_vault_read_secret", {
      p_id: connection.access_token_secret_id,
    });
    return accessToken ?? null;
  }

  const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", {
    p_id: connection.refresh_token_secret_id,
  });
  if (!refreshToken) return null;

  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
    }),
  });
  if (!tokenResp.ok) {
    console.error("Gmail token refresh failed:", await tokenResp.text());
    return null;
  }
  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", {
    p_id: connection.access_token_secret_id,
    p_secret: tokens.access_token,
  });
  await supabase
    .from("oauth_connections")
    .update({
      token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", connection.id);
  return tokens.access_token;
}

// Runs daily via pg_cron. Gmail watches expire ~7 days after registration;
// this renews anything expiring within the next 48 hours so a watch never
// silently lapses between runs. Independent of gmail-inbound-webhook's own
// watch registration at connect time - this is what keeps it alive long-term.
Deno.serve(async (req) => {
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const soon = new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString();

    const { data: syncStates, error: syncErr } = await supabase
      .from("gmail_sync_state")
      .select("id, oauth_connection_id, watch_expiration")
      .is("deleted_at", null)
      .lte("watch_expiration", soon);

    if (syncErr) {
      return new Response(JSON.stringify({ error: syncErr.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: Array<{ oauth_connection_id: number; status: string; error?: string }> = [];

    for (const syncState of syncStates ?? []) {
      const { data: connection } = await supabase
        .from("oauth_connections")
        .select("id, business_id, access_token_secret_id, refresh_token_secret_id, token_expires_at")
        .eq("id", syncState.oauth_connection_id)
        .eq("provider", "gmail")
        .eq("connection_status", "active")
        .is("deleted_at", null)
        .maybeSingle();

      if (!connection) continue; // disconnected since this row was flagged - nothing to renew

      const accessToken = await getFreshAccessToken(connection);
      if (!accessToken) {
        results.push({ oauth_connection_id: connection.id, status: "failed", error: "No usable access token" });
        continue;
      }

      const watchResp = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/watch", {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          topicName: "projects/nexaflow-499119/topics/gmail-inbound",
          labelIds: ["INBOX"],
          labelFilterAction: "include",
        }),
      });

      if (!watchResp.ok) {
        const errText = await watchResp.text();
        console.error(`Gmail watch renewal failed for connection ${connection.id}:`, errText);
        results.push({ oauth_connection_id: connection.id, status: "failed", error: errText });
        continue;
      }

      const watchData = await watchResp.json();
      await supabase
        .from("gmail_sync_state")
        .update({
          history_id: String(watchData.historyId ?? ""),
          watch_expiration: new Date(Number(watchData.expiration)).toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq("id", syncState.id);

      results.push({ oauth_connection_id: connection.id, status: "success" });
    }

    return new Response(JSON.stringify({ success: true, checked: syncStates?.length ?? 0, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("gmail-watch-renew error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});