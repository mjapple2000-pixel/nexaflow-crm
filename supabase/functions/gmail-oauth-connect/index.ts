import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const GOOGLE_REDIRECT_URI = Deno.env.get("GOOGLE_REDIRECT_URI")!;
const GOOGLE_OAUTH_STATE_SECRET = Deno.env.get("GOOGLE_OAUTH_STATE_SECRET")!;
const FRONTEND_URL = Deno.env.get("FRONTEND_URL") ?? "https://nexaflow-crm.web.app";

const GMAIL_SCOPES = [
  "https://www.googleapis.com/auth/gmail.modify",
  "https://www.googleapis.com/auth/userinfo.email",
].join(" ");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
};

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(GOOGLE_OAUTH_STATE_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function signState(businessId: number): Promise<string> {
  const payload = JSON.stringify({ business_id: businessId, nonce: crypto.randomUUID(), ts: Date.now() });
  const encodedPayload = btoa(payload).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const sig = await hmac(encodedPayload);
  return `${encodedPayload}.${sig}`;
}

async function verifyState(state: string): Promise<{ business_id: number } | null> {
  const [encodedPayload, sig] = state.split(".");
  if (!encodedPayload || !sig) return null;
  const expectedSig = await hmac(encodedPayload);
  if (expectedSig !== sig) return null;
  const payload = JSON.parse(atob(encodedPayload.replace(/-/g, "+").replace(/_/g, "/")));
  if (Date.now() - payload.ts > 10 * 60 * 1000) return null; // 10 min expiry
  return { business_id: payload.business_id };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const url = new URL(req.url);

  // Step 2: Google redirects here with ?code&state (or ?error if the user declined)
  if (req.method === "GET" && (url.searchParams.has("code") || url.searchParams.has("error"))) {
    if (url.searchParams.has("error")) {
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=user_declined`, 302);
    }

    const code = url.searchParams.get("code")!;
    const state = url.searchParams.get("state") ?? "";

    const verified = await verifyState(state);
    if (!verified) {
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=invalid_state`, 302);
    }

    try {
      const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          client_id: GOOGLE_CLIENT_ID,
          client_secret: GOOGLE_CLIENT_SECRET,
          redirect_uri: GOOGLE_REDIRECT_URI,
        }),
      });

      if (!tokenResp.ok) {
        console.error("Google token exchange failed:", await tokenResp.text());
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=token_exchange`, 302);
      }

      const tokens = await tokenResp.json();

      if (!tokens.refresh_token) {
        // Happens if the user previously connected and Google didn't re-issue a refresh
        // token this time. prompt=consent on the authorize URL should prevent this, but
        // guard anyway rather than silently storing an unusable connection.
        console.error("Google token exchange returned no refresh_token for business", verified.business_id);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=no_refresh_token`, 302);
      }

      // Google's consent screen shows Gmail access as a separately-checkable
      // permission (unchecked by default) whenever a restricted scope is
      // requested. A user can click through without checking it, in which
      // case Google silently omits gmail.modify from the granted token
      // instead of erroring - the connect flow would otherwise "succeed"
      // with a token that can't actually read or send mail. Catch that here
      // rather than discovering it later when watch()/send calls fail.
      const grantedScopes = (tokens.scope ?? "").split(" ");
      if (!grantedScopes.includes("https://www.googleapis.com/auth/gmail.modify")) {
        console.error("Gmail scope not granted for business", verified.business_id, "- granted scopes:", tokens.scope);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=missing_gmail_scope`, 302);
      }

      const userInfoResp = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
        headers: { Authorization: `Bearer ${tokens.access_token}` },
      });
      const userInfo = userInfoResp.ok ? await userInfoResp.json() : {};

      const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

      const { data: accessSecretId, error: accessErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.access_token,
        p_name: `gmail_access_${verified.business_id}_${Date.now()}`,
      });
      const { data: refreshSecretId, error: refreshErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.refresh_token,
        p_name: `gmail_refresh_${verified.business_id}_${Date.now()}`,
      });

      if (accessErr || refreshErr) {
        console.error("Vault store failed:", accessErr, refreshErr);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=vault_store`, 302);
      }

      const expiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();

      // Partial unique index (business_id, provider WHERE deleted_at IS NULL)
      // can't be targeted by ON CONFLICT - check-then-update-or-insert instead.
      const { data: existingConnection } = await supabase
        .from("oauth_connections")
        .select("id")
        .eq("business_id", verified.business_id)
        .eq("provider", "gmail")
        .maybeSingle();

      let connectionRow: { id: number } | null = null;
      let writeErr: unknown = null;

      if (existingConnection) {
        const { data, error } = await supabase
          .from("oauth_connections")
          .update({
            connected_account_email: userInfo.email ?? null,
            access_token_secret_id: accessSecretId,
            refresh_token_secret_id: refreshSecretId,
            token_expires_at: expiresAt,
            connection_status: "active",
            deleted_at: null,
            updated_at: new Date().toISOString(),
          })
          .eq("id", existingConnection.id)
          .select("id")
          .single();
        connectionRow = data;
        writeErr = error;
      } else {
        const { data, error } = await supabase
          .from("oauth_connections")
          .insert({
            business_id: verified.business_id,
            provider: "gmail",
            connected_account_email: userInfo.email ?? null,
            access_token_secret_id: accessSecretId,
            refresh_token_secret_id: refreshSecretId,
            token_expires_at: expiresAt,
            connection_status: "active",
          })
          .select("id")
          .single();
        connectionRow = data;
        writeErr = error;
      }

      if (writeErr || !connectionRow) {
        console.error("oauth_connections write failed:", writeErr);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=save_failed`, 302);
      }

      // Ensure a gmail_sync_state row exists for this connection.
      // Partial unique index (oauth_connection_id WHERE deleted_at IS NULL) can't
      // be targeted by ON CONFLICT - check-then-update-or-insert, same as above.
      const { data: existingSyncState } = await supabase
        .from("gmail_sync_state")
        .select("id")
        .eq("oauth_connection_id", connectionRow.id)
        .maybeSingle();

      let syncStateId: number | null = existingSyncState?.id ?? null;

      if (existingSyncState) {
        const { error: syncUpdateErr } = await supabase
          .from("gmail_sync_state")
          .update({ deleted_at: null, updated_at: new Date().toISOString() })
          .eq("id", existingSyncState.id);
        if (syncUpdateErr) console.error("gmail_sync_state update failed:", syncUpdateErr);
      } else {
        const { data: insertedSyncState, error: syncInsertErr } = await supabase
          .from("gmail_sync_state")
          .insert({ oauth_connection_id: connectionRow.id, business_id: verified.business_id })
          .select("id")
          .single();
        if (syncInsertErr) console.error("gmail_sync_state insert failed:", syncInsertErr);
        syncStateId = insertedSyncState?.id ?? null;
      }

      // Register a Gmail watch so Google pushes new-mail notifications to our
      // Pub/Sub topic. Watches expire ~7 days out; a separate renewal cron
      // (built next) re-registers this before then. Best-effort: a failure
      // here doesn't fail the connect flow - the fallback polling cron
      // (built separately) covers a business whose watch never registered.
      if (syncStateId) {
        try {
          const watchResp = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/watch", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${tokens.access_token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              topicName: "projects/nexaflow-499119/topics/gmail-inbound",
              labelIds: ["INBOX"],
              labelFilterAction: "include",
            }),
          });
          if (watchResp.ok) {
            const watchData = await watchResp.json();
            await supabase
              .from("gmail_sync_state")
              .update({
                history_id: String(watchData.historyId ?? ""),
                watch_expiration: new Date(Number(watchData.expiration)).toISOString(),
                updated_at: new Date().toISOString(),
              })
              .eq("id", syncStateId);
          } else {
            console.error("Gmail watch() registration failed:", await watchResp.text());
          }
        } catch (watchErr) {
          console.error("Gmail watch() exception:", watchErr);
        }
      }

      await supabase
        .from("businesses")
        .update({ gmail_connected: true })
        .eq("id", verified.business_id);

      return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=connected`, 302);
    } catch (e) {
      console.error("Gmail OAuth callback exception:", e);
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&gmail=error&reason=exception`, 302);
    }
  }

  // Step 1: Flutter calls this to get the authorize URL
  if (req.method === "POST") {
    try {
      const authHeader = req.headers.get("Authorization") ?? "";
      const jwt = authHeader.replace("Bearer ", "");
      if (!jwt) {
        return new Response(JSON.stringify({ error: "Missing auth token" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
      const { data: userData, error: userErr } = await anonClient.auth.getUser(jwt);
      if (userErr || !userData?.user) {
        return new Response(JSON.stringify({ error: "Invalid session" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
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

      let resolvedBusinessId: number | null = null;

      if (profile?.business_id) {
        if (!isOwner && !isSuperuser) {
          return new Response(JSON.stringify({ error: "Not authorized to connect Gmail" }), {
            status: 403,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedBusinessId = profile.business_id;
      } else if (isSuperuser) {
        let body: { business_id?: number } = {};
        try {
          body = await req.json();
        } catch (_) {
          // no body sent
        }
        if (!body.business_id) {
          return new Response(JSON.stringify({ error: "business_id required for superuser session" }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        const { data: biz } = await serviceClient
          .from("businesses")
          .select("id")
          .eq("id", body.business_id)
          .maybeSingle();
        if (!biz) {
          return new Response(JSON.stringify({ error: "Business not found" }), {
            status: 404,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedBusinessId = biz.id;
      } else {
        return new Response(JSON.stringify({ error: "Not authorized to connect Gmail" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Plan gate: Growth+ only (beta bypasses via check_plan_feature's own beta handling)
      const { data: allowed } = await serviceClient.rpc("check_plan_feature", {
        p_business_id: resolvedBusinessId,
        p_feature: "gmail_sync",
      });
      if (!allowed) {
        return new Response(JSON.stringify({ error: "Gmail sync requires the Growth plan or higher" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const state = await signState(resolvedBusinessId!);
      const authorizeUrl =
        `https://accounts.google.com/o/oauth2/v2/auth` +
        `?client_id=${encodeURIComponent(GOOGLE_CLIENT_ID)}` +
        `&response_type=code` +
        `&access_type=offline` +
        `&prompt=consent` +
        `&scope=${encodeURIComponent(GMAIL_SCOPES)}` +
        `&redirect_uri=${encodeURIComponent(GOOGLE_REDIRECT_URI)}` +
        `&state=${encodeURIComponent(state)}`;

      return new Response(JSON.stringify({ authorize_url: authorizeUrl }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (e) {
      console.error("Gmail OAuth start exception:", e);
      return new Response(JSON.stringify({ error: "Internal error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  // Step 3: Flutter calls this to disconnect Gmail
  if (req.method === "DELETE") {
    try {
      const authHeader = req.headers.get("Authorization") ?? "";
      const jwt = authHeader.replace("Bearer ", "");
      if (!jwt) {
        return new Response(JSON.stringify({ error: "Missing auth token" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
      const { data: userData, error: userErr } = await anonClient.auth.getUser(jwt);
      if (userErr || !userData?.user) {
        return new Response(JSON.stringify({ error: "Invalid session" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
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

      let resolvedBusinessId: number | null = null;

      if (profile?.business_id) {
        if (!isOwner && !isSuperuser) {
          return new Response(JSON.stringify({ error: "Not authorized to disconnect Gmail" }), {
            status: 403,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedBusinessId = profile.business_id;
      } else if (isSuperuser) {
        let body: { business_id?: number } = {};
        try {
          body = await req.json();
        } catch (_) {
          // no body sent
        }
        if (!body.business_id) {
          return new Response(JSON.stringify({ error: "business_id required for superuser session" }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedBusinessId = body.business_id;
      } else {
        return new Response(JSON.stringify({ error: "Not authorized to disconnect Gmail" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: connection } = await serviceClient
        .from("oauth_connections")
        .select("id, access_token_secret_id, refresh_token_secret_id")
        .eq("business_id", resolvedBusinessId)
        .eq("provider", "gmail")
        .is("deleted_at", null)
        .maybeSingle();

      if (!connection) {
        return new Response(JSON.stringify({ error: "No active Gmail connection found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Best-effort revoke with Google - proceed with local cleanup even if
      // this fails (e.g. token already invalid on Google's side).
      try {
        const { data: refreshToken } = await serviceClient.rpc("qb_vault_read_secret", {
          p_id: connection.refresh_token_secret_id,
        });
        if (refreshToken) {
          await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(refreshToken)}`, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
          });
        }
      } catch (revokeErr) {
        console.error("Google token revoke failed (continuing with local cleanup):", revokeErr);
      }

      await serviceClient.rpc("qb_vault_delete_secret", { p_id: connection.access_token_secret_id });
      await serviceClient.rpc("qb_vault_delete_secret", { p_id: connection.refresh_token_secret_id });

      await serviceClient
        .from("oauth_connections")
        .update({
          connection_status: "disconnected",
          deleted_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq("id", connection.id);

      await serviceClient
        .from("gmail_sync_state")
        .update({ deleted_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("oauth_connection_id", connection.id);

      await serviceClient
        .from("businesses")
        .update({ gmail_connected: false })
        .eq("id", resolvedBusinessId);

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (e) {
      console.error("Gmail disconnect exception:", e);
      return new Response(JSON.stringify({ error: "Internal error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  return new Response("Not found", { status: 404, headers: corsHeaders });
});