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

type TokenResult = { accessToken: string; realmId: string } | { error: string };

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

function splitName(fullName: string): { given: string; family: string } {
  const parts = fullName.trim().split(/\s+/);
  if (parts.length === 0 || (parts.length === 1 && parts[0] === "")) return { given: "", family: "" };
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

// Get an existing QuickBooks customer link for this lead, or create one on
// the fly. Invoices can arrive before the contact trigger has ever fired
// (e.g. an invoice approved seconds after a lead is first created), so this
// function can't just assume the customer already exists in QuickBooks.
async function ensureCustomerSynced(
  businessId: number,
  leadId: number,
  realmId: string,
  headers: Record<string, string>,
): Promise<{ qbCustomerId: string } | { error: string }> {
  const { data: existingLink } = await supabase
    .from("accounting_customer_links")
    .select("qb_customer_id")
    .eq("lead_id", leadId)
    .eq("provider", "quickbooks")
    .is("deleted_at", null)
    .maybeSingle();

  if (existingLink?.qb_customer_id) return { qbCustomerId: existingLink.qb_customer_id };

  const { data: lead } = await supabase
    .from("leads")
    .select("id, lead_name, lead_email, lead_phone, lead_address")
    .eq("id", leadId)
    .maybeSingle();

  if (!lead) return { error: "Lead not found for this invoice" };

  let createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/customer`, {
    method: "POST",
    headers,
    body: JSON.stringify(buildCustomerPayload(lead)),
  });

  if (!createResp.ok) {
    const errBody = await createResp.text();
    if (errBody.includes("Duplicate Name Exists") || errBody.includes("6240")) {
      const retryName = `${lead.lead_name || "Lead"} (${lead.id})`;
      createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/customer`, {
        method: "POST",
        headers,
        body: JSON.stringify(buildCustomerPayload(lead, retryName)),
      });
    }
    if (!createResp.ok) return { error: await createResp.text() };
  }

  const created = await createResp.json();
  const qbCustomerId = created.Customer?.Id;
  if (!qbCustomerId) return { error: "QuickBooks did not return a customer Id" };

  await supabase.from("accounting_customer_links").upsert(
    {
      business_id: businessId,
      lead_id: leadId,
      provider: "quickbooks",
      qb_customer_id: qbCustomerId,
      deleted_at: null,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "lead_id,provider" },
  );

  return { qbCustomerId };
}

// Every QuickBooks invoice line needs an ItemRef. NexaFlow's line items
// don't map to real QuickBooks Items, so one generic service Item is
// created per business (once) and reused for every line — its id is
// cached on accounting_connections to avoid a lookup on every sync.
async function getDefaultItemId(
  businessId: number,
  realmId: string,
  headers: Record<string, string>,
): Promise<{ itemId: string } | { error: string }> {
  const { data: conn } = await supabase
    .from("accounting_connections")
    .select("qb_default_item_id")
    .eq("business_id", businessId)
    .eq("provider", "quickbooks")
    .maybeSingle();

  if (conn?.qb_default_item_id) return { itemId: conn.qb_default_item_id };

  const searchQuery = encodeURIComponent(`select * from Item where Name = 'Services'`);
  const searchResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/query?query=${searchQuery}`, { headers });
  if (searchResp.ok) {
    const body = await searchResp.json();
    const existing = body.QueryResponse?.Item?.[0];
    if (existing?.Id) {
      await supabase
        .from("accounting_connections")
        .update({ qb_default_item_id: existing.Id })
        .eq("business_id", businessId)
        .eq("provider", "quickbooks");
      return { itemId: existing.Id };
    }
  }

  const acctQuery = encodeURIComponent(`select * from Account where AccountType = 'Income' maxresults 1`);
  const acctResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/query?query=${acctQuery}`, { headers });
  if (!acctResp.ok) return { error: "Could not query Income accounts in QuickBooks" };
  const acctBody = await acctResp.json();
  const incomeAccount = acctBody.QueryResponse?.Account?.[0];
  if (!incomeAccount?.Id) return { error: "No Income account found in QuickBooks company" };

  const createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/item`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      Name: "Services",
      Type: "Service",
      IncomeAccountRef: { value: incomeAccount.Id },
    }),
  });
  if (!createResp.ok) return { error: await createResp.text() };
  const created = await createResp.json();
  const itemId = created.Item?.Id;
  if (!itemId) return { error: "QuickBooks did not return an Item Id" };

  await supabase
    .from("accounting_connections")
    .update({ qb_default_item_id: itemId })
    .eq("business_id", businessId)
    .eq("provider", "quickbooks");

  return { itemId };
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
    entity_type: "invoice",
    local_id: params.localId,
    qb_id: params.qbId,
    direction: "to_qb",
    status: params.status,
    error_message: params.errorMessage ?? null,
    synced_at: new Date().toISOString(),
  }).then(() => {}, (e) => console.error("Sync log write failed:", e));
}

function toQbDate(value: string | null): string | undefined {
  if (!value) return undefined;
  return new Date(value).toISOString().slice(0, 10);
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
    const { invoice_id } = await req.json();
    if (!invoice_id) {
      return new Response(JSON.stringify({ error: "invoice_id required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: invoice, error: invErr } = await supabase
      .from("invoices")
      .select("id, business_id, contact_id, invoice_number, status, due_date, notes, deleted_at")
      .eq("id", invoice_id)
      .maybeSingle();

    if (invErr || !invoice) {
      return new Response(JSON.stringify({ error: "Invoice not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (invoice.deleted_at || invoice.status === "draft") {
      return new Response(JSON.stringify({ skipped: true, reason: "Invoice deleted or still draft" }), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (!invoice.contact_id) {
      await logSync({
        businessId: invoice.business_id,
        localId: invoice.id,
        qbId: null,
        status: "failed",
        errorMessage: "Invoice has no linked contact — cannot determine QuickBooks Customer",
      });
      return new Response(JSON.stringify({ error: "Invoice has no linked contact" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const tokenResult = await getValidAccessToken(invoice.business_id);
    if ("error" in tokenResult) {
      await logSync({
        businessId: invoice.business_id,
        localId: invoice.id,
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
      .from("accounting_invoice_links")
      .select("qb_invoice_id")
      .eq("invoice_id", invoice.id)
      .eq("provider", "quickbooks")
      .is("deleted_at", null)
      .maybeSingle();

    // ── Void handling ──────────────────────────────────────────────────
    if (invoice.status === "void") {
      if (!existingLink?.qb_invoice_id) {
        return new Response(JSON.stringify({ skipped: true, reason: "Voided invoice was never synced" }), {
          headers: { "Content-Type": "application/json" },
        });
      }
      const getResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/invoice/${existingLink.qb_invoice_id}`, {
        headers: qbHeaders,
      });
      if (!getResp.ok) {
        const err = await getResp.text();
        await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: existingLink.qb_invoice_id, status: "failed", errorMessage: err });
        return new Response(JSON.stringify({ error: err }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      const current = await getResp.json();
      const voidResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/invoice?operation=void`, {
        method: "POST",
        headers: qbHeaders,
        body: JSON.stringify({ Id: existingLink.qb_invoice_id, SyncToken: current.Invoice?.SyncToken }),
      });
      if (!voidResp.ok) {
        const err = await voidResp.text();
        await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: existingLink.qb_invoice_id, status: "failed", errorMessage: err });
        return new Response(JSON.stringify({ error: err }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: existingLink.qb_invoice_id, status: "success" });
      return new Response(JSON.stringify({ success: true, voided: true }), { headers: { "Content-Type": "application/json" } });
    }

    // ── Resolve customer ───────────────────────────────────────────────
    const customerResult = await ensureCustomerSynced(invoice.business_id, invoice.contact_id, realmId, qbHeaders);
    if ("error" in customerResult) {
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: null, status: "failed", errorMessage: customerResult.error });
      return new Response(JSON.stringify({ error: customerResult.error }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    const { qbCustomerId } = customerResult;

    // ── Resolve default line-item Item ─────────────────────────────────
    const itemResult = await getDefaultItemId(invoice.business_id, realmId, qbHeaders);
    if ("error" in itemResult) {
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: null, status: "failed", errorMessage: itemResult.error });
      return new Response(JSON.stringify({ error: itemResult.error }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    const { itemId } = itemResult;

    // ── Line items ──────────────────────────────────────────────────────
    const { data: lineItems } = await supabase
      .from("line_items")
      .select("description, quantity, unit_price, total, sort_order")
      .eq("parent_type", "invoice")
      .eq("parent_id", invoice.id)
      .is("deleted_at", null)
      .order("sort_order");

    if (!lineItems || lineItems.length === 0) {
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: null, status: "failed", errorMessage: "Invoice has no line items to sync" });
      return new Response(JSON.stringify({ error: "No line items" }), { status: 200, headers: { "Content-Type": "application/json" } });
    }

    const qbLines = lineItems.map((li) => {
      const qty = Number(li.quantity);
      const amount = Number(li.total);
      // NexaFlow's `total` already has any line-level discount applied, so it
      // won't generally equal quantity × unit_price. QuickBooks requires
      // Amount === Qty × UnitPrice exactly, so we derive an effective unit
      // price from the real total rather than reusing NexaFlow's pre-discount
      // rate — this keeps Qty/Rate detail visible in QuickBooks while always
      // satisfying its own math check.
      const effectiveQty = qty > 0 ? qty : 1;
      const effectiveUnitPrice = amount / effectiveQty;
      return {
        DetailType: "SalesItemLineDetail",
        Amount: amount,
        Description: li.description,
        SalesItemLineDetail: {
          ItemRef: { value: itemId },
          Qty: effectiveQty,
          UnitPrice: effectiveUnitPrice,
        },
      };
    });

    const basePayload: Record<string, unknown> = {
      CustomerRef: { value: qbCustomerId },
      DocNumber: invoice.invoice_number,
      Line: qbLines,
    };
    const dueDate = toQbDate(invoice.due_date);
    if (dueDate) basePayload.DueDate = dueDate;
    if (invoice.notes) basePayload.CustomerMemo = { value: invoice.notes };

    let qbInvoiceId: string | null = null;
    let lastError: string | null = null;

    if (existingLink?.qb_invoice_id) {
      const getResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/invoice/${existingLink.qb_invoice_id}`, {
        headers: qbHeaders,
      });
      if (getResp.ok) {
        const current = await getResp.json();
        const updatePayload = {
          ...basePayload,
          Id: existingLink.qb_invoice_id,
          SyncToken: current.Invoice?.SyncToken,
        };
        const updateResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/invoice`, {
          method: "POST",
          headers: qbHeaders,
          body: JSON.stringify(updatePayload),
        });
        if (updateResp.ok) {
          const updated = await updateResp.json();
          qbInvoiceId = updated.Invoice?.Id ?? existingLink.qb_invoice_id;
        } else {
          lastError = await updateResp.text();
        }
      } else {
        lastError = await getResp.text();
      }
    } else {
      const createResp = await fetch(`${QB_API_BASE}/v3/company/${realmId}/invoice`, {
        method: "POST",
        headers: qbHeaders,
        body: JSON.stringify(basePayload),
      });
      if (createResp.ok) {
        const created = await createResp.json();
        qbInvoiceId = created.Invoice?.Id ?? null;
      } else {
        lastError = await createResp.text();
      }
    }

    if (qbInvoiceId) {
      await supabase.from("accounting_invoice_links").upsert(
        {
          business_id: invoice.business_id,
          invoice_id: invoice.id,
          provider: "quickbooks",
          qb_invoice_id: qbInvoiceId,
          deleted_at: null,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "invoice_id,provider" },
      );
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: qbInvoiceId, status: "success" });
      return new Response(JSON.stringify({ success: true, qb_invoice_id: qbInvoiceId }), {
        headers: { "Content-Type": "application/json" },
      });
    } else {
      await logSync({ businessId: invoice.business_id, localId: invoice.id, qbId: null, status: "failed", errorMessage: lastError ?? "Unknown error" });
      return new Response(JSON.stringify({ success: false, error: lastError }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
  } catch (e: any) {
    console.error("quickbooks-sync-invoice error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});