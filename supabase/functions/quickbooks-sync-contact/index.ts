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

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function getValidAccessToken(businessId: number): Promise<{ accessToken: string; realmId: string } | { error: string }> {
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
    const errText = await tokenResp.text();
    console.error("QB token refresh failed:", errText);
    await supabase
      .from("accounting_connections")
      .update({ connection_status: "error" })
      .eq("business_id", businessId)
      .eq("provider", "quickbooks");
    return { error: "Token refresh failed — connection marked as needing reconnect" };
  }

  const tokens = await tokenResp.json();

  await supabase.rpc("qb_vault_update_secret", {
    p_id: conn.access_token_secret_id,
    p_secret: tokens.access_token,
  });
  await supabase.rpc("qb_vault_update_secret", {
    p_id: conn.refresh_token_secret_id,
    p_secret: tokens.refresh_token,
  });

  const newExpiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString();
  await supabase
    .from("accounting_connections")
    .update({ token_expires_at: newExpiresAt, updated_at: new Date().toISOString() })
    .eq("business_id", businessId)
    .eq("provider", "quickbooks");

  return { accessToken: tokens.access_token, realmId: conn.qb_realm_id };
}

function splitName(fullName: string): { given: string; family: string } {
  const parts = fullName.trim().split(/\s+/);
  if (parts.length === 0 || (parts.length === 1 && parts[0] === "")) {
    return { given: "", family: "" };
  }
  return { given: parts[0], family: parts.slice(1).join(" ") || "" };
}

function buildCustomerPayload(lead: any, displayNameOverride?: string) {
  const { given, family } = splitName(lead.lead_name || "");
  const payload: Record<string, unknown> = {
    DisplayName: displayNameOverride || lead.lead_name || `Lead ${lead.id}`,
  };
  if (given) payload.GivenName = given;
  if (family) payload.FamilyName = family;
  if (lead.lead_email) payload.PrimaryEmailAddr = { Address: lead.lead_email };
  if (lead.lead_phone) payload.PrimaryPhone = { FreeFormNumber: lead.lead_phone };
  if (lead.lead_address) payload.BillAddr = { Line1: lead.lead_address };
  return payload;
}

async function logSync(params: {
  businessId: number;
  localId: string;
  qbId: string | null;
  status: "success" | "failed";
  errorMessage?: string;
}) {
  await supabase.from("accounting_sync_log").insert({
    business_id: params.businessId,
    entity_type: "contact",
    local_id: params.localId,
    qb_id: params.qbId,
    direction: "to_qb",
    status: params.status,
    error_message: params.errorMessage ?? null,
    synced_at: new Date().toISOString(),
  }).then(() => {}, (e) => console.error("Sync log write failed:", e));
}

Deno.serve(async (req) => {
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { lead_id } = await req.json();
    if (!lead_id) {
      return new Response(JSON.stringify({ error: "lead_id required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: lead, error: leadErr } = await supabase
      .from("leads")
      .select("id, business_id, lead_name, lead_email, lead_phone, lead_address, deleted_at")
      .eq("id", lead_id)
      .maybeSingle();

    if (leadErr || !lead) {
      return new Response(JSON.stringify({ error: "Lead not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (lead.deleted_at) {
      return new Response(JSON.stringify({ skipped: true, reason: "Lead is deleted" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const tokenResult = await getValidAccessToken(lead.business_id);
    if ("error" in tokenResult) {
      await logSync({
        businessId: lead.business_id,
        localId: String(lead.id),
        qbId: null,
        status: "failed",
        errorMessage: tokenResult.error,
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

    const { data: existingLink } = await supabase
      .from("accounting_customer_links")
      .select("qb_customer_id")
      .eq("lead_id", lead.id)
      .eq("provider", "quickbooks")
      .is("deleted_at", null)
      .maybeSingle();

    let qbCustomerId: string | null = null;
    let lastError: string | null = null;

    if (existingLink?.qb_customer_id) {
      const getResp = await fetch(
        `${QB_API_BASE}/v3/company/${realmId}/customer/${existingLink.qb_customer_id}`,
        { headers: qbHeaders },
      );
      if (getResp.ok) {
        const current = await getResp.json();
        const syncToken = current.Customer?.SyncToken;
        const updatePayload = {
          ...buildCustomerPayload(lead),
          Id: existingLink.qb_customer_id,
          SyncToken: syncToken,
          sparse: true,
        };
        const updateResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/customer`, {
          method: "POST",
          headers: qbHeaders,
          body: JSON.stringify(updatePayload),
        });
        if (updateResp.ok) {
          const updated = await updateResp.json();
          qbCustomerId = updated.Customer?.Id ?? existingLink.qb_customer_id;
        } else {
          lastError = await updateResp.text();
        }
      } else {
        lastError = await getResp.text();
      }
    } else {
      const createPayload = buildCustomerPayload(lead);
      let createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/customer`, {
        method: "POST",
        headers: qbHeaders,
        body: JSON.stringify(createPayload),
      });

      if (!createResp.ok) {
        const errBody = await createResp.text();
        if (errBody.includes("Duplicate Name Exists") || errBody.includes("6240")) {
          const retryName = `${lead.lead_name || "Lead"} (${lead.id})`;
          createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/customer`, {
            method: "POST",
            headers: qbHeaders,
            body: JSON.stringify(buildCustomerPayload(lead, retryName)),
          });
          if (!createResp.ok) {
            lastError = await createResp.text();
          }
        } else {
          lastError = errBody;
        }
      }

      if (createResp.ok) {
        const created = await createResp.json();
        qbCustomerId = created.Customer?.Id ?? null;
      }
    }

    if (qbCustomerId) {
      await supabase.from("accounting_customer_links").upsert(
        {
          business_id: lead.business_id,
          lead_id: lead.id,
          provider: "quickbooks",
          qb_customer_id: qbCustomerId,
          deleted_at: null,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "lead_id,provider" },
      );
      await logSync({
        businessId: lead.business_id,
        localId: String(lead.id),
        qbId: qbCustomerId,
        status: "success",
      });
      return new Response(JSON.stringify({ success: true, qb_customer_id: qbCustomerId }), {
        headers: { "Content-Type": "application/json" },
      });
    } else {
      await logSync({
        businessId: lead.business_id,
        localId: String(lead.id),
        qbId: null,
        status: "failed",
        errorMessage: lastError ?? "Unknown error",
      });
      return new Response(JSON.stringify({ success: false, error: lastError }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
  } catch (e: any) {
    console.error("quickbooks-sync-contact error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});