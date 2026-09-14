import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const MICROSOFT_CLIENT_ID = Deno.env.get("MICROSOFT_CLIENT_ID")!;
const MICROSOFT_CLIENT_SECRET = Deno.env.get("MICROSOFT_CLIENT_SECRET")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Must match microsoft-oauth-callback's scopes exactly.
const MICROSOFT_SCOPES = [
  "offline_access",
  "https://graph.microsoft.com/Mail.ReadWrite",
  "https://graph.microsoft.com/Mail.Send",
  "https://graph.microsoft.com/User.Read",
].join(" ");

// After this many consecutive failed renewal attempts (not counting a
// decisive invalid_grant, which escalates immediately), connection_status
// is escalated to 'token_error'. At this cron's 12-hour cadence, 3 misses
// is ~36 hours of continuous failure before flagging — comfortable margin
// before a subscription actually lapses at its ~3-day expiry.
const FAILURE_THRESHOLD = 3;

type RefreshResult = { accessToken: string } | { error: "invalid_grant" | "other"; detail: string };

// Same vault pattern as microsoft-graph-webhook, but returns a typed result
// instead of null so the caller can tell a decisive revocation (invalid_grant)
// apart from a transient failure — that distinction drives the escalation
// logic below, which gmail-watch-renew doesn't need since Google doesn't
// require this file to make that call.
async function getFreshAccessToken(connection: {
  id: number;
  access_token_secret_id: string;
  refresh_token_secret_id: string;
  token_expires_at: string;
}): Promise<RefreshResult> {
  const expiresAt = new Date(connection.token_expires_at).getTime();
  if (expiresAt > Date.now() + 2 * 60 * 1000) {
    const { data: accessToken } = await supabase.rpc("qb_vault_read_secret", { p_id: connection.access_token_secret_id });
    if (accessToken) return { accessToken };
    return { error: "other", detail: "cached access token unreadable from vault" };
  }

  const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", { p_id: connection.refresh_token_secret_id });
  if (!refreshToken) return { error: "other", detail: "refresh token unreadable from vault" };

  const tokenResp = await fetch("https://login.microsoftonline.com/common/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: MICROSOFT_CLIENT_ID,
      client_secret: MICROSOFT_CLIENT_SECRET,
      scope: MICROSOFT_SCOPES,
    }),
  });

  if (!tokenResp.ok) {
    const errText = await tokenResp.text();
    console.error(`renew-graph-subscriptions: token refresh failed for connection ${connection.id}:`, errText);
    return { error: errText.includes("invalid_grant") ? "invalid_grant" : "other", detail: errText };
  }

  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", { p_id: connection.access_token_secret_id, p_secret: tokens.access_token });
  if (tokens.refresh_token) {
    await supabase.rpc("qb_vault_update_secret", { p_id: connection.refresh_token_secret_id, p_secret: tokens.refresh_token });
  }
  await supabase
    .from("oauth_connections")
    .update({ token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(), updated_at: new Date().toISOString() })
    .eq("id", connection.id);
  return { accessToken: tokens.access_token };
}

// Registers a brand-new Graph subscription — same call microsoft-oauth-callback
// makes at connect time. Used both for a row that never got one (Test
// Roofer's current orphaned state) and as the fallback when a PATCH renewal
// comes back 404 because the old subscription has already lapsed.
async function createSubscription(accessToken: string): Promise<{ id: string; clientState: string; expirationDateTime: string } | null> {
  const clientState = crypto.randomUUID();
  const expirationDateTime = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000 - 5 * 60 * 1000).toISOString();
  const resp = await fetch("https://graph.microsoft.com/v1.0/subscriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      changeType: "created",
      notificationUrl: `${SUPABASE_URL}/functions/v1/microsoft-graph-webhook`,
      resource: "me/mailFolders('Inbox')/messages",
      expirationDateTime,
      clientState,
    }),
  });
  if (!resp.ok) {
    console.error("renew-graph-subscriptions: subscription creation failed:", await resp.text());
    return null;
  }
  const data = await resp.json();
  return { id: data.id, clientState, expirationDateTime: data.expirationDateTime ?? expirationDateTime };
}

// Extends an existing subscription in place — cheaper than recreating and
// preserves the existing client_state, so no downstream re-verification
// logic changes. Returns null on any failure, including 404 (subscription
// already gone), which the caller falls back to createSubscription for.
async function renewSubscription(accessToken: string, graphSubscriptionId: string): Promise<{ expirationDateTime: string } | { notFound: true } | null> {
  const expirationDateTime = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000 - 5 * 60 * 1000).toISOString();
  const resp = await fetch(`https://graph.microsoft.com/v1.0/subscriptions/${graphSubscriptionId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ expirationDateTime }),
  });
  if (resp.status === 404) return { notFound: true };
  if (!resp.ok) {
    console.error(`renew-graph-subscriptions: PATCH renewal failed for subscription ${graphSubscriptionId}:`, await resp.text());
    return null;
  }
  const data = await resp.json();
  return { expirationDateTime: data.expirationDateTime ?? expirationDateTime };
}

// Runs on a 12-hour cron via pg_cron — tighter than gmail-watch-renew's
// daily cadence, since Graph subscriptions max out at ~3 days versus
// Gmail's ~7. Catches three cases in one query: rows expiring within 24h,
// rows that never got a subscription registered (expiration_datetime IS
// NULL), and rows with no graph_subscription_id at all — the last two
// cover Test Roofer's current orphaned row without any separate
// disconnect/reconnect step.
Deno.serve(async (req) => {
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const soon = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

    const { data: subs, error: subsErr } = await supabase
      .from("email_sync_subscriptions")
      .select("id, oauth_connection_id, graph_subscription_id, expiration_datetime, consecutive_renewal_failures")
      .is("deleted_at", null)
      .or(`graph_subscription_id.is.null,expiration_datetime.is.null,expiration_datetime.lte.${soon}`);

    if (subsErr) {
      return new Response(JSON.stringify({ error: subsErr.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const results: Array<{ oauth_connection_id: number; status: string; detail?: string }> = [];

    for (const sub of subs ?? []) {
      const { data: connection } = await supabase
        .from("oauth_connections")
        .select("id, business_id, access_token_secret_id, refresh_token_secret_id, token_expires_at, connection_status")
        .eq("id", sub.oauth_connection_id)
        .eq("provider", "microsoft")
        .in("connection_status", ["active", "token_error"])
        .is("deleted_at", null)
        .maybeSingle();

      // No matching connection = disconnected, or already revoked (and
      // therefore not worth retrying) since this row was flagged.
      if (!connection) continue;

      const refreshResult = await getFreshAccessToken(connection);

      if ("error" in refreshResult) {
        if (refreshResult.error === "invalid_grant") {
          // Decisive: Microsoft is telling us consent was revoked. No
          // amount of retrying fixes this — the business must reconnect.
          await supabase.from("oauth_connections").update({
            connection_status: "revoked",
            updated_at: new Date().toISOString(),
          }).eq("id", connection.id);
          results.push({ oauth_connection_id: connection.id, status: "revoked", detail: refreshResult.detail });
          continue;
        }

        const nextFailureCount = (sub.consecutive_renewal_failures ?? 0) + 1;
        const updates: Record<string, unknown> = {
          consecutive_renewal_failures: nextFailureCount,
          updated_at: new Date().toISOString(),
        };
        await supabase.from("email_sync_subscriptions").update(updates).eq("id", sub.id);

        if (nextFailureCount >= FAILURE_THRESHOLD && connection.connection_status === "active") {
          await supabase.from("oauth_connections").update({
            connection_status: "token_error",
            updated_at: new Date().toISOString(),
          }).eq("id", connection.id);
        }
        results.push({ oauth_connection_id: connection.id, status: "token_refresh_failed", detail: refreshResult.detail });
        continue;
      }

      const accessToken = refreshResult.accessToken;
      let renewalOutcome: { expirationDateTime: string; newSubscriptionId?: string; newClientState?: string } | null = null;

      if (sub.graph_subscription_id) {
        const renewed = await renewSubscription(accessToken, sub.graph_subscription_id);
        if (renewed && !("notFound" in renewed)) {
          renewalOutcome = { expirationDateTime: renewed.expirationDateTime };
        } else {
          // Either PATCH failed outright, or came back 404 (subscription
          // already lapsed) — either way, fall back to a fresh registration.
          const created = await createSubscription(accessToken);
          if (created) {
            renewalOutcome = { expirationDateTime: created.expirationDateTime, newSubscriptionId: created.id, newClientState: created.clientState };
          }
        }
      } else {
        // Never had one — this is the Test Roofer orphaned-row case.
        const created = await createSubscription(accessToken);
        if (created) {
          renewalOutcome = { expirationDateTime: created.expirationDateTime, newSubscriptionId: created.id, newClientState: created.clientState };
        }
      }

      if (!renewalOutcome) {
        const nextFailureCount = (sub.consecutive_renewal_failures ?? 0) + 1;
        await supabase.from("email_sync_subscriptions").update({
          consecutive_renewal_failures: nextFailureCount,
          updated_at: new Date().toISOString(),
        }).eq("id", sub.id);

        if (nextFailureCount >= FAILURE_THRESHOLD && connection.connection_status === "active") {
          await supabase.from("oauth_connections").update({
            connection_status: "token_error",
            updated_at: new Date().toISOString(),
          }).eq("id", connection.id);
        }
        results.push({ oauth_connection_id: connection.id, status: "subscription_renewal_failed" });
        continue;
      }

      const subUpdate: Record<string, unknown> = {
        expiration_datetime: renewalOutcome.expirationDateTime,
        last_renewed_at: new Date().toISOString(),
        consecutive_renewal_failures: 0,
        updated_at: new Date().toISOString(),
      };
      if (renewalOutcome.newSubscriptionId) {
        subUpdate.graph_subscription_id = renewalOutcome.newSubscriptionId;
        subUpdate.client_state = renewalOutcome.newClientState;
      }
      await supabase.from("email_sync_subscriptions").update(subUpdate).eq("id", sub.id);

      // Self-heal: this connection was flagged token_error but renewal just
      // succeeded, so the underlying issue must have resolved on its own.
      if (connection.connection_status === "token_error") {
        await supabase.from("oauth_connections").update({
          connection_status: "active",
          updated_at: new Date().toISOString(),
        }).eq("id", connection.id);
      }

      results.push({ oauth_connection_id: connection.id, status: renewalOutcome.newSubscriptionId ? "recreated" : "renewed" });
    }

    return new Response(JSON.stringify({ success: true, checked: subs?.length ?? 0, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("renew-graph-subscriptions error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});