import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID") ?? "";
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "";
const MICROSOFT_CLIENT_ID = Deno.env.get("MICROSOFT_CLIENT_ID") ?? "";
const MICROSOFT_CLIENT_SECRET = Deno.env.get("MICROSOFT_CLIENT_SECRET") ?? "";

const MICROSOFT_SCOPES = [
  "offline_access",
  "https://graph.microsoft.com/Mail.ReadWrite",
  "https://graph.microsoft.com/Mail.Send",
  "https://graph.microsoft.com/User.Read",
].join(" ");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type RefreshOutcome =
  | { ok: true; accessToken: string; expiresIn: number; newRefreshToken?: string }
  | { ok: false; decisive: boolean; detail: string };

// Attempts a silent refresh against the correct provider's token endpoint.
// `decisive: true` means the failure means the refresh token itself is
// dead (invalid_grant) — no amount of retrying fixes that, only a full
// OAuth re-consent will. Anything else is treated as transient.
async function attemptRefresh(provider: "gmail" | "microsoft", refreshToken: string): Promise<RefreshOutcome> {
  if (provider === "gmail") {
    const resp = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
      }),
    });
    if (!resp.ok) {
      const text = await resp.text();
      return { ok: false, decisive: text.includes("invalid_grant"), detail: text };
    }
    const tokens = await resp.json();
    return { ok: true, accessToken: tokens.access_token, expiresIn: tokens.expires_in };
  }

  // microsoft
  const resp = await fetch("https://login.microsoftonline.com/common/oauth2/v2.0/token", {
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
  if (!resp.ok) {
    const text = await resp.text();
    return { ok: false, decisive: text.includes("invalid_grant"), detail: text };
  }
  const tokens = await resp.json();
  return { ok: true, accessToken: tokens.access_token, expiresIn: tokens.expires_in, newRefreshToken: tokens.refresh_token };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Not found", { status: 404, headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");
    if (!jwt) {
      return new Response(JSON.stringify({ error: "Missing auth token" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: userData, error: userErr } = await anonClient.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const serviceClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: profile } = await serviceClient
      .from("profiles")
      .select("business_id, role")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const { data: superuserRow } = await serviceClient
      .from("superusers")
      .select("user_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const isSuperuser = superuserRow != null;
    const isOwner = profile?.role === "owner";

    let body: { provider?: string; business_id?: number } = {};
    try { body = await req.json(); } catch (_) { /* no body */ }

    const provider = body.provider;
    if (provider !== "gmail" && provider !== "microsoft") {
      return new Response(JSON.stringify({ error: "provider must be 'gmail' or 'microsoft'" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let resolvedBusinessId: number | null = null;
    if (profile?.business_id) {
      if (!isOwner && !isSuperuser) {
        return new Response(JSON.stringify({ error: "Not authorized" }), {
          status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      resolvedBusinessId = profile.business_id;
    } else if (isSuperuser) {
      if (!body.business_id) {
        return new Response(JSON.stringify({ error: "business_id required for superuser session" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      resolvedBusinessId = body.business_id;
    } else {
      return new Response(JSON.stringify({ error: "Not authorized" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: connection } = await serviceClient
      .from("oauth_connections")
      .select("id, connection_status, access_token_secret_id, refresh_token_secret_id")
      .eq("business_id", resolvedBusinessId)
      .eq("provider", provider)
      .is("deleted_at", null)
      .maybeSingle();

    if (!connection) {
      return new Response(JSON.stringify({ error: "No connection found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Already revoked — a silent refresh can never fix this, don't waste
    // a round trip to the provider confirming what we already know.
    if (connection.connection_status === "revoked") {
      return new Response(JSON.stringify({ success: false, needs_full_reconnect: true, reason: "revoked" }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: refreshToken } = await serviceClient.rpc("qb_vault_read_secret", {
      p_id: connection.refresh_token_secret_id,
    });
    if (!refreshToken) {
      return new Response(JSON.stringify({ success: false, needs_full_reconnect: true, reason: "missing_refresh_token" }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const outcome = await attemptRefresh(provider, refreshToken);

    if (!outcome.ok) {
      if (outcome.decisive) {
        await serviceClient.from("oauth_connections").update({
          connection_status: "revoked",
          updated_at: new Date().toISOString(),
        }).eq("id", connection.id);
        return new Response(JSON.stringify({ success: false, needs_full_reconnect: true, reason: "revoked" }), {
          status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      // Transient failure — leave connection_status as-is (token_error),
      // report the error, let the user try again or fall back manually.
      console.error(`reconnect-oauth-connection: transient refresh failure for connection ${connection.id}:`, outcome.detail);
      return new Response(JSON.stringify({ success: false, needs_full_reconnect: false, error: outcome.detail }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    await serviceClient.rpc("qb_vault_update_secret", {
      p_id: connection.access_token_secret_id,
      p_secret: outcome.accessToken,
    });
    if (outcome.newRefreshToken) {
      await serviceClient.rpc("qb_vault_update_secret", {
        p_id: connection.refresh_token_secret_id,
        p_secret: outcome.newRefreshToken,
      });
    }
    await serviceClient.from("oauth_connections").update({
      token_expires_at: new Date(Date.now() + outcome.expiresIn * 1000).toISOString(),
      connection_status: "active",
      updated_at: new Date().toISOString(),
    }).eq("id", connection.id);

    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("reconnect-oauth-connection exception:", e);
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});