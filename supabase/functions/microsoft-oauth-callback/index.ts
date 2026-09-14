import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const MICROSOFT_CLIENT_ID = Deno.env.get("MICROSOFT_CLIENT_ID")!;
const MICROSOFT_CLIENT_SECRET = Deno.env.get("MICROSOFT_CLIENT_SECRET")!;
const MICROSOFT_REDIRECT_URI = Deno.env.get("MICROSOFT_REDIRECT_URI")!;
const MICROSOFT_OAUTH_STATE_SECRET = Deno.env.get("MICROSOFT_OAUTH_STATE_SECRET")!;
const FRONTEND_URL = Deno.env.get("FRONTEND_URL") ?? "https://nexaflow-crm.web.app";

// offline_access is required to get a refresh_token back — Microsoft omits
// it by default, unlike Google which returns one automatically when
// access_type=offline is set. Mail.ReadWrite covers both reading inbound
// mail and the send-as-reply flow; Mail.Send is also requested explicitly
// since ReadWrite alone does not guarantee send permission on every tenant
// configuration. User.Read is the minimum needed to resolve the connected
// mailbox's own address after consent.
const MICROSOFT_SCOPES = [
  "offline_access",
  "https://graph.microsoft.com/Mail.ReadWrite",
  "https://graph.microsoft.com/Mail.Send",
  "https://graph.microsoft.com/User.Read",
].join(" ");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
};

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(MICROSOFT_OAUTH_STATE_SECRET),
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

  // Step 2: Microsoft redirects here with ?code&state (or ?error if the user declined)
  if (req.method === "GET" && (url.searchParams.has("code") || url.searchParams.has("error"))) {
    if (url.searchParams.has("error")) {
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=user_declined`, 302);
    }

    const code = url.searchParams.get("code")!;
    const state = url.searchParams.get("state") ?? "";

    const verified = await verifyState(state);
    if (!verified) {
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=invalid_state`, 302);
    }

    try {
      // Microsoft's token endpoint is tenant-scoped. "common" accepts both
      // personal Microsoft accounts and any Azure AD work/school tenant —
      // the app registration itself is what actually controls who can
      // consent, this URL segment doesn't further restrict it.
      const tokenResp = await fetch("https://login.microsoftonline.com/common/oauth2/v2.0/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          client_id: MICROSOFT_CLIENT_ID,
          client_secret: MICROSOFT_CLIENT_SECRET,
          redirect_uri: MICROSOFT_REDIRECT_URI,
          scope: MICROSOFT_SCOPES,
        }),
      });

      if (!tokenResp.ok) {
        console.error("Microsoft token exchange failed:", await tokenResp.text());
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=token_exchange`, 302);
      }

      const tokens = await tokenResp.json();

      if (!tokens.refresh_token) {
        // Same guard as Gmail's — offline_access should always yield a
        // refresh_token, but don't silently store an unusable connection
        // if a tenant policy ever withholds it.
        console.error("Microsoft token exchange returned no refresh_token for business", verified.business_id);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=no_refresh_token`, 302);
      }

      const grantedScopes = (tokens.scope ?? "").toLowerCase();
      if (!grantedScopes.includes("mail.readwrite") || !grantedScopes.includes("mail.send")) {
        console.error("Mail scopes not granted for business", verified.business_id, "- granted scopes:", tokens.scope);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=missing_mail_scope`, 302);
      }

      const userInfoResp = await fetch("https://graph.microsoft.com/v1.0/me", {
        headers: { Authorization: `Bearer ${tokens.access_token}` },
      });
      const userInfo = userInfoResp.ok ? await userInfoResp.json() : {};
      // mail is null for some account types (e.g. certain school tenants) —
      // userPrincipalName is always present and is the correct fallback,
      // same address used to sign in.
      const connectedEmail = userInfo.mail ?? userInfo.userPrincipalName ?? null;

      const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

      const { data: accessSecretId, error: accessErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.access_token,
        p_name: `microsoft_access_${verified.business_id}_${Date.now()}`,
      });
      const { data: refreshSecretId, error: refreshErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.refresh_token,
        p_name: `microsoft_refresh_${verified.business_id}_${Date.now()}`,
      });

      if (accessErr || refreshErr) {
        console.error("Vault store failed:", accessErr, refreshErr);
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=vault_store`, 302);
      }

      const expiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();

      // Partial unique index (business_id, provider WHERE deleted_at IS NULL)
      // can't be targeted by ON CONFLICT - check-then-update-or-insert, same
      // pattern as gmail-oauth-connect.
      const { data: existingConnection } = await supabase
        .from("oauth_connections")
        .select("id")
        .eq("business_id", verified.business_id)
        .eq("provider", "microsoft")
        .maybeSingle();

      let connectionRow: { id: number } | null = null;
      let writeErr: unknown = null;

      if (existingConnection) {
        const { data, error } = await supabase
          .from("oauth_connections")
          .update({
            connected_account_email: connectedEmail,
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
            provider: "microsoft",
            connected_account_email: connectedEmail,
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
        return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=save_failed`, 302);
      }

      // Ensure an email_sync_subscriptions row exists for this connection.
      // Same check-then-update-or-insert pattern as gmail_sync_state above —
      // the unique index here is also partial (WHERE deleted_at IS NULL).
      const { data: existingSub } = await supabase
        .from("email_sync_subscriptions")
        .select("id")
        .eq("oauth_connection_id", connectionRow.id)
        .maybeSingle();

      let subId: number | null = existingSub?.id ?? null;

      if (existingSub) {
        const { error: subUpdateErr } = await supabase
          .from("email_sync_subscriptions")
          .update({ deleted_at: null, updated_at: new Date().toISOString() })
          .eq("id", existingSub.id);
        if (subUpdateErr) console.error("email_sync_subscriptions update failed:", subUpdateErr);
      } else {
        const { data: insertedSub, error: subInsertErr } = await supabase
          .from("email_sync_subscriptions")
          .insert({ oauth_connection_id: connectionRow.id, business_id: verified.business_id })
          .select("id")
          .single();
        if (subInsertErr) console.error("email_sync_subscriptions insert failed:", subInsertErr);
        subId = insertedSub?.id ?? null;
      }

      // Register a Graph subscription so Microsoft pushes new-mail
      // notifications to microsoft-graph-webhook. Graph subscriptions max
      // out at ~3 days for mail resources and must be renewed well before
      // then — renew-graph-subscriptions (built separately) handles that.
      // client_state is echoed back on every notification and MUST be
      // verified there, the same way receive-email verifies Mailgun's HMAC
      // signature — without it, anyone who finds the webhook URL could post
      // a forged notification.
      if (subId) {
        try {
          const clientState = crypto.randomUUID();
          const expirationDateTime = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000 - 5 * 60 * 1000).toISOString();
          const subResp = await fetch("https://graph.microsoft.com/v1.0/subscriptions", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${tokens.access_token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              changeType: "created",
              notificationUrl: `${SUPABASE_URL}/functions/v1/microsoft-graph-webhook`,
              resource: "me/mailFolders('Inbox')/messages",
              expirationDateTime,
              clientState,
            }),
          });
          if (subResp.ok) {
            const subData = await subResp.json();
            await supabase
              .from("email_sync_subscriptions")
              .update({
                graph_subscription_id: subData.id ?? null,
                client_state: clientState,
                expiration_datetime: subData.expirationDateTime ?? expirationDateTime,
                last_renewed_at: new Date().toISOString(),
                updated_at: new Date().toISOString(),
              })
              .eq("id", subId);
          } else {
            console.error("Graph subscription registration failed:", await subResp.text());
          }
        } catch (subErr) {
          console.error("Graph subscription exception:", subErr);
        }
      }

      await supabase
        .from("businesses")
        .update({ outlook_connected: true })
        .eq("id", verified.business_id);

      return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=connected`, 302);
    } catch (e) {
      console.error("Microsoft OAuth callback exception:", e);
      return Response.redirect(`${FRONTEND_URL}/settings?section=email&outlook=error&reason=exception`, 302);
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
          return new Response(JSON.stringify({ error: "Not authorized to connect Outlook" }), {
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
        return new Response(JSON.stringify({ error: "Not authorized to connect Outlook" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Plan gate: Pro only (beta bypasses via check_plan_feature's own beta handling)
      const { data: allowed } = await serviceClient.rpc("check_plan_feature", {
        p_business_id: resolvedBusinessId,
        p_feature: "outlook_sync",
      });
      if (!allowed) {
        return new Response(JSON.stringify({ error: "Outlook sync requires the Pro plan" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const state = await signState(resolvedBusinessId!);
      const authorizeUrl =
        `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` +
        `?client_id=${encodeURIComponent(MICROSOFT_CLIENT_ID)}` +
        `&response_type=code` +
        `&response_mode=query` +
        `&prompt=consent` +
        `&scope=${encodeURIComponent(MICROSOFT_SCOPES)}` +
        `&redirect_uri=${encodeURIComponent(MICROSOFT_REDIRECT_URI)}` +
        `&state=${encodeURIComponent(state)}`;

      return new Response(JSON.stringify({ authorize_url: authorizeUrl }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (e) {
      console.error("Microsoft OAuth start exception:", e);
      return new Response(JSON.stringify({ error: "Internal error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  // Step 3: Flutter calls this to disconnect Outlook
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
          return new Response(JSON.stringify({ error: "Not authorized to disconnect Outlook" }), {
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
        return new Response(JSON.stringify({ error: "Not authorized to disconnect Outlook" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: connection } = await serviceClient
        .from("oauth_connections")
        .select("id, access_token_secret_id, refresh_token_secret_id")
        .eq("business_id", resolvedBusinessId)
        .eq("provider", "microsoft")
        .is("deleted_at", null)
        .maybeSingle();

      if (!connection) {
        return new Response(JSON.stringify({ error: "No active Outlook connection found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Best-effort: delete the Graph subscription and revoke consent.
      // Proceed with local cleanup regardless of outcome, same as Gmail's
      // disconnect flow — a token already invalid on Microsoft's side
      // shouldn't block the business from disconnecting locally.
      try {
        const { data: sub } = await serviceClient
          .from("email_sync_subscriptions")
          .select("graph_subscription_id")
          .eq("oauth_connection_id", connection.id)
          .is("deleted_at", null)
          .maybeSingle();

        if (sub?.graph_subscription_id) {
          const { data: accessToken } = await serviceClient.rpc("qb_vault_read_secret", {
            p_id: connection.access_token_secret_id,
          });
          if (accessToken) {
            await fetch(`https://graph.microsoft.com/v1.0/subscriptions/${sub.graph_subscription_id}`, {
              method: "DELETE",
              headers: { Authorization: `Bearer ${accessToken}` },
            });
          }
        }
      } catch (subDeleteErr) {
        console.error("Graph subscription delete failed (continuing with local cleanup):", subDeleteErr);
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
        .from("email_sync_subscriptions")
        .update({ deleted_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("oauth_connection_id", connection.id);

      await serviceClient
        .from("businesses")
        .update({ outlook_connected: false })
        .eq("id", resolvedBusinessId);

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (e) {
      console.error("Outlook disconnect exception:", e);
      return new Response(JSON.stringify({ error: "Internal error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  return new Response("Not found", { status: 404, headers: corsHeaders });
});