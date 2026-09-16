// JB-SMS-03: Automated Invoice Overdue Reminders
// Cron-triggered (every 15 min), same shape as send-quote-followups /
// send-appointment-reminders — a separate dedicated function, NOT routed
// through run-automation / process-scheduled-automations.
//
// Two independent behaviors per invoice, per Mike's call this session:
//   1) STATUS FLIP (unconditional, every business, no toggle/plan gate):
//      any invoice still at status='sent' whose due_date has passed gets
//      flipped to 'overdue'. This just wires up the invoice_status enum
//      value that already existed but nothing was setting.
//   2) SMS REMINDER (gated): toggle + plan + manual-automation-guard,
//      exactly mirroring quote_followups' gating shape, keyed off
//      invoice_overdue_days counted from due_date (not sent_at).
//
// Dedup via invoices.overdue_reminder_sent_at, compare-and-swap on write —
// same pattern as quotes.quote_followup_sent_at / appointments.reminder_sent_at.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SUPABASE_SERVICE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? "";
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

// Default copy — no manual "Invoice Overdue" automation template exists yet
// (this ticket is the first thing to use this trigger_type at all), so this
// is the only copy in play until/unless Mike builds a manual one later.
const DEFAULT_OVERDUE_MESSAGE =
  "Hi {{name}}, this is a friendly reminder that invoice {{invoice_number}} for {{amount}} from {{business}} is now past due.{{payment_link}} Please let us know if you have any questions!";

async function dbFetch(path: string, options: RequestInit = {}) {
  const url = `${SUPABASE_URL}/rest/v1/${path}`;
  const res = await fetch(url, {
    ...options,
    headers: {
      "apikey": SUPABASE_SERVICE_KEY,
      "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
      "Content-Type": "application/json",
      "Prefer": "return=representation",
      ...(options.headers || {}),
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`DB error ${res.status}: ${text}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

async function checkPlanFeature(businessId: number, feature: string): Promise<boolean> {
  const result = await dbFetch("rpc/check_plan_feature", {
    method: "POST",
    body: JSON.stringify({ p_business_id: businessId, p_feature: feature }),
  });
  return result === true;
}

// Future-proofing guard, mirroring quote_followups' hasManualFollowupAutomation
// exactly: if Mike later builds a manual "invoice_overdue" automation for a
// business, this function steps aside rather than double-texting. No live
// automation uses this trigger_type yet, so this currently always resolves
// false — that's expected, not a bug.
async function hasManualFollowupAutomation(businessId: number): Promise<boolean> {
  const rows = await dbFetch(
    `automations?business_id=eq.${businessId}&trigger_type=eq.invoice_overdue&is_active=eq.true&deleted_at=is.null&select=id`
  );
  return Array.isArray(rows) && rows.length > 0;
}

async function sendSms(to: string, from: string, body: string): Promise<{ ok: boolean; error?: string }> {
  const res = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`,
    {
      method: "POST",
      headers: {
        "Authorization": `Basic ${btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: to, From: from, Body: body }).toString(),
    }
  );
  if (!res.ok) {
    const err = await res.text();
    return { ok: false, error: err };
  }
  return { ok: true };
}

function formatAmount(amountDue: string | number): string {
  const n = typeof amountDue === "string" ? parseFloat(amountDue) : amountDue;
  return `$${n.toFixed(2)}`;
}

async function processInvoice(invoice: any): Promise<{ invoice_id: string; status: string; error?: string }> {
  const businessId = invoice.business_id;

  // --- Step 1: unconditional status flip, independent of toggle/plan ---
  // Only touches rows still at 'sent' — an invoice already flipped to
  // 'overdue' by a prior run, or moved to 'paid'/'void' since, is untouched.
  if (invoice.status === "sent") {
    const flipped = await dbFetch(
      `invoices?id=eq.${invoice.id}&status=eq.sent`,
      {
        method: "PATCH",
        body: JSON.stringify({ status: "overdue" }),
      }
    );
    if (Array.isArray(flipped) && flipped.length > 0) {
      invoice.status = "overdue";
    }
  }

  // --- Step 2: gated SMS reminder ---
  if (invoice.overdue_reminder_sent_at) {
    return { invoice_id: invoice.id, status: "skipped", error: "Reminder already sent" };
  }

  const businesses = await dbFetch(`businesses?id=eq.${businessId}&select=id,business_name,ai_phone_number,auto_invoice_overdue_enabled,invoice_overdue_days`);
  const business = businesses?.[0];
  if (!business) {
    return { invoice_id: invoice.id, status: "skipped", error: "Business not found" };
  }

  if (!business.auto_invoice_overdue_enabled) {
    return { invoice_id: invoice.id, status: "skipped", error: "Toggle off for this business" };
  }

  // Per-business delay counted from due_date (not sent_at) — reminder fires
  // N days after the invoice was due, not N days after it was sent.
  const overdueDays = business.invoice_overdue_days ?? 3;
  const dueAt = new Date(invoice.due_date).getTime() + overdueDays * 24 * 60 * 60 * 1000;
  if (Date.now() < dueAt) {
    return { invoice_id: invoice.id, status: "skipped", error: "Not due yet" };
  }

  const allowed = await checkPlanFeature(businessId, "invoice_overdue_reminders");
  if (!allowed) {
    return { invoice_id: invoice.id, status: "skipped", error: "Not allowed on this business's plan" };
  }

  const hasManual = await hasManualFollowupAutomation(businessId);
  if (hasManual) {
    return { invoice_id: invoice.id, status: "skipped", error: "Business already has a manual invoice overdue automation" };
  }

  if (!business.ai_phone_number) {
    return { invoice_id: invoice.id, status: "skipped", error: "No Twilio number configured" };
  }

  const leads = invoice.contact_id ? await dbFetch(`leads?id=eq.${invoice.contact_id}&select=lead_name,lead_phone`) : null;
  const lead = leads?.[0];
  const phone = lead?.lead_phone;
  if (!phone) {
    return { invoice_id: invoice.id, status: "skipped", error: "No phone number on file for this lead" };
  }

  // Payment link is optional — not every invoice has one generated yet.
  let paymentLinkText = "";
  if (invoice.payment_link_id) {
    const links = await dbFetch(`payment_links?id=eq.${invoice.payment_link_id}&select=stripe_payment_link_url`);
    const url = links?.[0]?.stripe_payment_link_url;
    if (url) {
      paymentLinkText = ` Pay here: ${url}`;
    }
  }

  const leadName = lead?.lead_name || "";
  const bizName = business.business_name || "us";
  const body = DEFAULT_OVERDUE_MESSAGE
    .replace("{{name}}", leadName || "there")
    .replace("{{invoice_number}}", invoice.invoice_number || "")
    .replace("{{amount}}", formatAmount(invoice.amount_due))
    .replace("{{business}}", bizName)
    .replace("{{payment_link}}", paymentLinkText);

  const result = await sendSms(phone, business.ai_phone_number, body);
  if (!result.ok) {
    return { invoice_id: invoice.id, status: "failed", error: result.error };
  }

  const updated = await dbFetch(
    `invoices?id=eq.${invoice.id}&overdue_reminder_sent_at=is.null`,
    {
      method: "PATCH",
      body: JSON.stringify({ overdue_reminder_sent_at: new Date().toISOString() }),
    }
  );

  if (!updated || updated.length === 0) {
    return { invoice_id: invoice.id, status: "sent_but_race_on_flag" };
  }

  return { invoice_id: invoice.id, status: "sent" };
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
    // Candidate pool: any non-deleted invoice still 'sent' or already
    // 'overdue' whose due_date has passed. Covers both freshly-crossed
    // invoices (still 'sent', need the status flip) and already-overdue
    // ones (need only the reminder check). Per-business day threshold and
    // reminder-sent dedupe are both checked inside processInvoice since
    // they vary per business/row — can't be pushed into this filter.
    const nowIso = new Date().toISOString();
    const invoices = await dbFetch(
      `invoices?status=in.(sent,overdue)&due_date=not.is.null&due_date=lt.${nowIso}&deleted_at=is.null` +
      `&select=id,business_id,contact_id,due_date,status,invoice_number,amount_due,payment_link_id,overdue_reminder_sent_at`
    );

    if (!invoices || invoices.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const results = [];
    for (const invoice of invoices) {
      try {
        results.push(await processInvoice(invoice));
      } catch (e: any) {
        console.error(`Failed invoice ${invoice.id}:`, e.message);
        results.push({ invoice_id: invoice.id, status: "error", error: e.message });
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    console.error("send-invoice-overdue-reminders error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});