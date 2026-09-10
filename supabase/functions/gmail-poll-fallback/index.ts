import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const GMAIL_PUBSUB_SECRET = Deno.env.get("GMAIL_PUBSUB_SECRET") ?? "";
const WEBHOOK_URL = "https://rllriopqojaraceytdno.supabase.co/functions/v1/gmail-inbound-webhook";

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function encodeBase64Url(str: string): string {
  const bytes = new TextEncoder().encode(str);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Same refresh pattern as gmail-inbound-webhook / gmail-watch-renew.
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
    console.error("gmail-poll-fallback: token refresh failed:", await tokenResp.text());
    return null;
  }
  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", { p_id: connection.access_token_secret_id, p_secret: tokens.access_token });
  await supabase
    .from("oauth_connections")
    .update({ token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(), updated_at: new Date().toISOString() })
    .eq("id", connection.id);
  return tokens.access_token;
}

// Runs every 15 minutes via pg_cron. Google Pub/Sub push delivery is
// at-least-once but not guaranteed - if a push is ever dropped, inbound
// mail would sit unprocessed with nothing to catch it. This calls
// users.getProfile for each active Gmail connection to get the mailbox's
// real current historyId, then feeds gmail-inbound-webhook the exact same
// envelope shape a genuine Pub/Sub push sends - reusing all of its existing
// processing logic rather than duplicating the state machine here.
Deno.serve(async (req) => {
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { data: connections, error: connErr } = await supabase
      .from("oauth_connections")
      .select("id, business_id, access_token_secret_id, refresh_token_secret_id, token_expires_at")
      .eq("provider", "gmail")
      .eq("connection_status", "active")
      .is("deleted_at", null);

    if (connErr) {
      return new Response(JSON.stringify({ error: connErr.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: Array<{ connection_id: number; status: string; error?: string }> = [];

    for (const connection of connections ?? []) {
      const accessToken = await getFreshAccessToken(connection);
      if (!accessToken) {
        results.push({ connection_id: connection.id, status: "failed", error: "No usable access token" });
        continue;
      }

      const profileResp = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/profile", {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!profileResp.ok) {
        const errText = await profileResp.text();
        console.error(`gmail-poll-fallback: getProfile failed for connection ${connection.id}:`, errText);
        results.push({ connection_id: connection.id, status: "failed", error: errText });
        continue;
      }
      const profile = await profileResp.json();
      const emailAddress = profile.emailAddress as string | undefined;
      const historyId = profile.historyId as string | undefined;
      if (!emailAddress || !historyId) {
        results.push({ connection_id: connection.id, status: "failed", error: "Missing emailAddress/historyId in profile" });
        continue;
      }

      const envelope = encodeBase64Url(JSON.stringify({ emailAddress, historyId }));
      const webhookResp = await fetch(`${WEBHOOK_URL}?secret=${GMAIL_PUBSUB_SECRET}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: { data: envelope } }),
      });

      if (!webhookResp.ok) {
        const errText = await webhookResp.text();
        console.error(`gmail-poll-fallback: webhook call failed for connection ${connection.id}:`, errText);
        results.push({ connection_id: connection.id, status: "failed", error: errText });
        continue;
      }

      results.push({ connection_id: connection.id, status: "polled" });
    }

    return new Response(JSON.stringify({ success: true, checked: connections?.length ?? 0, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("gmail-poll-fallback error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});