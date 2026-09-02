import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const QB_CLIENT_ID = Deno.env.get("QUICKBOOKS_CLIENT_ID")!;
const QB_CLIENT_SECRET = Deno.env.get("QUICKBOOKS_CLIENT_SECRET")!;
const QB_ENV = Deno.env.get("QUICKBOOKS_ENVIRONMENT") ?? "sandbox";
const QB_API_BASE = QB_ENV === "production"
  ? "https://quickbooks.api.intuit.com"
  : "https://sandbox-quickbooks.api.intuit.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

type TokenResult = { accessToken: string; realmId: string } | { error: string };

// Same on-demand refresh pattern used in quickbooks-sync-invoice and
// quickbooks-sync-hours — kept inline per this codebase's convention of
// self-contained edge functions rather than a shared import.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

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

    let body: { business_id?: number } = {};
    try {
      body = await req.json();
    } catch (_) {
      // no body sent
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id, role")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const { data: superuserRow } = await supabase
      .from("superusers")
      .select("user_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const isSuperuser = superuserRow != null;
    const isOwnerOrAdmin = profile?.role === "owner" || profile?.role === "admin";

    let businessId: number | null = null;
    if (profile?.business_id) {
      if (!isOwnerOrAdmin && !isSuperuser) {
        return new Response(JSON.stringify({ error: "Not authorized" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      businessId = profile.business_id;
    } else if (isSuperuser && body.business_id) {
      businessId = body.business_id;
    } else {
      return new Response(JSON.stringify({ error: "Not authorized" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const tokenResult = await getValidAccessToken(businessId!);
    if ("error" in tokenResult) {
      return new Response(JSON.stringify({ error: tokenResult.error }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const { accessToken, realmId } = tokenResult;

    const query = encodeURIComponent("select * from Employee where Active = true maxresults 1000");
    const resp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/query?query=${query}`, {
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Accept": "application/json",
      },
    });

    if (!resp.ok) {
      const errText = await resp.text();
      return new Response(JSON.stringify({ error: errText }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const data = await resp.json();
    const rawEmployees: any[] = data.QueryResponse?.Employee ?? [];
    const employees = rawEmployees.map((e) => ({
      id: e.Id,
      name: e.DisplayName ?? `${e.GivenName ?? ""} ${e.FamilyName ?? ""}`.trim() ?? e.Id,
    }));

    return new Response(JSON.stringify({ employees }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("quickbooks-list-employees error:", message);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});