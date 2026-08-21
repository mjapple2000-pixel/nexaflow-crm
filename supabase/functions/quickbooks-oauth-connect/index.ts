import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const QB_CLIENT_ID = Deno.env.get("QUICKBOOKS_CLIENT_ID")!;
const QB_CLIENT_SECRET = Deno.env.get("QUICKBOOKS_CLIENT_SECRET")!;
const QB_REDIRECT_URI = Deno.env.get("QUICKBOOKS_REDIRECT_URI")!;
const QB_STATE_SECRET = Deno.env.get("QUICKBOOKS_STATE_SECRET")!;
const FRONTEND_URL = Deno.env.get("FRONTEND_URL") ?? "https://nexaflow-crm.web.app";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

async function hmac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(QB_STATE_SECRET),
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

  // Step 2: QuickBooks redirects here with ?code&realmId&state
  if (req.method === "GET" && url.searchParams.has("code")) {
    const code = url.searchParams.get("code")!;
    const realmId = url.searchParams.get("realmId")!;
    const state = url.searchParams.get("state") ?? "";

    const verified = await verifyState(state);
    if (!verified) {
      return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=error&reason=invalid_state`, 302);
    }

    try {
      const tokenResp = await fetch("https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer", {
        method: "POST",
        headers: {
          "Authorization": `Basic ${btoa(`${QB_CLIENT_ID}:${QB_CLIENT_SECRET}`)}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
        },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          redirect_uri: QB_REDIRECT_URI,
        }),
      });

      if (!tokenResp.ok) {
        console.error("QB token exchange failed:", await tokenResp.text());
        return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=error&reason=token_exchange`, 302);
      }

      const tokens = await tokenResp.json();
      const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

      const { data: accessSecretId, error: accessErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.access_token,
        p_name: `qb_access_${verified.business_id}_${Date.now()}`,
      });
      const { data: refreshSecretId, error: refreshErr } = await supabase.rpc("qb_vault_store_secret", {
        p_secret: tokens.refresh_token,
        p_name: `qb_refresh_${verified.business_id}_${Date.now()}`,
      });

      if (accessErr || refreshErr) {
        console.error("Vault store failed:", accessErr, refreshErr);
        return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=error&reason=vault_store`, 302);
      }

      const expiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();

      const { error: upsertErr } = await supabase
        .from("accounting_connections")
        .upsert(
          {
            business_id: verified.business_id,
            provider: "quickbooks",
            qb_realm_id: realmId,
            access_token_secret_id: accessSecretId,
            refresh_token_secret_id: refreshSecretId,
            token_expires_at: expiresAt,
            connection_status: "connected",
            deleted_at: null,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "business_id,provider" },
        );

      if (upsertErr) {
        console.error("accounting_connections upsert failed:", upsertErr);
        return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=error&reason=save_failed`, 302);
      }

      return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=connected`, 302);
    } catch (e) {
      console.error("QB OAuth callback exception:", e);
      return Response.redirect(`${FRONTEND_URL}/settings?section=integrations&qb=error&reason=exception`, 302);
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
        // Normal case: business_id always comes from the caller's own profile,
        // never trusted from the client body.
        if (!isOwner && !isSuperuser) {
          return new Response(JSON.stringify({ error: "Not authorized to connect accounting integrations" }), {
            status: 403,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedBusinessId = profile.business_id;
      } else if (isSuperuser) {
        // Superuser has no profiles row by design, so there's no business_id
        // to pull server-side. Accept it from the request body only in this
        // one case, and verify the business actually exists before trusting it.
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
        return new Response(JSON.stringify({ error: "Not authorized to connect accounting integrations" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const state = await signState(resolvedBusinessId!);
      const authorizeUrl =
        `https://appcenter.intuit.com/connect/oauth2` +
        `?client_id=${encodeURIComponent(QB_CLIENT_ID)}` +
        `&response_type=code` +
        `&scope=${encodeURIComponent("com.intuit.quickbooks.accounting")}` +
        `&redirect_uri=${encodeURIComponent(QB_REDIRECT_URI)}` +
        `&state=${encodeURIComponent(state)}`;

      return new Response(JSON.stringify({ authorize_url: authorizeUrl }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    } catch (e) {
      console.error("QB OAuth start exception:", e);
      return new Response(JSON.stringify({ error: "Internal error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  return new Response("Not found", { status: 404, headers: corsHeaders });
});