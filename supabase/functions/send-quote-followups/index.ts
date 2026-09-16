// JB-SMS-02: Automated Quote Follow-Ups
// Cron-triggered (every 15 min), same shape as send-appointment-reminders —
// a separate dedicated function, NOT routed through run-automation /
// process-scheduled-automations, so a business's existing JG-13 manual
// "quote_not_responded" automation (e.g. Test Roofer's automation id 16)
// is never duplicated or touched. This function only ever fires for
// businesses that have NO manual automation for that trigger.
// Dedup via quotes.quote_followup_sent_at, compare-and-swap on write —
// same pattern as appointments.reminder_sent_at.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SUPABASE_SERVICE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? "";
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

// Default copy — used because most businesses won't have a manually-built
// "Quote Follow-Up" automation template to read from (that's an optional,
// separately-built thing, like Test Roofer's automation id 16). Same
// {{name}}/{{business}} tokens and wording as that manual template, for
// consistency.
const DEFAULT_FOLLOWUP_MESSAGE =
  "Hi {{name}}, just following up on the estimate we sent over from {{business}}. Let us know if you have any questions or would like to move forward!";

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

// Guard against double-texting a customer whose business already has a
// manual "quote_not_responded" automation built (e.g. Test Roofer's
// automation id 16, "Quote Follow-Up — 3 Days"). If one exists, let it do
// its job via the existing run-automation / process-scheduled-automations
// path — this function skips entirely rather than sending a second message.
async function hasManualFollowupAutomation(businessId: number): Promise<boolean> {
  const rows = await dbFetch(
    `automations?business_id=eq.${businessId}&trigger_type=eq.quote_not_responded&is_active=eq.true&deleted_at=is.null&select=id`
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

async function processQuote(quote: any): Promise<{ quote_id: string; status: string; error?: string }> {
  const businessId = quote.business_id;

  const businesses = await dbFetch(`businesses?id=eq.${businessId}&select=id,business_name,ai_phone_number,auto_quote_followup_enabled,quote_followup_days`);
  const business = businesses?.[0];
  if (!business) {
    return { quote_id: quote.id, status: "skipped", error: "Business not found" };
  }

  if (!business.auto_quote_followup_enabled) {
    return { quote_id: quote.id, status: "skipped", error: "Toggle off for this business" };
  }

  // Per-business follow-up delay — not due yet, skip until a later run
  // catches it once enough time has passed.
  const followupDays = business.quote_followup_days ?? 3;
  const dueAt = new Date(quote.sent_at).getTime() + followupDays * 24 * 60 * 60 * 1000;
  if (Date.now() < dueAt) {
    return { quote_id: quote.id, status: "skipped", error: "Not due yet" };
  }

  const allowed = await checkPlanFeature(businessId, "quote_followups");
  if (!allowed) {
    return { quote_id: quote.id, status: "skipped", error: "Not allowed on this business's plan" };
  }

  const hasManual = await hasManualFollowupAutomation(businessId);
  if (hasManual) {
    return { quote_id: quote.id, status: "skipped", error: "Business already has a manual quote follow-up automation" };
  }

  if (!business.ai_phone_number) {
    return { quote_id: quote.id, status: "skipped", error: "No Twilio number configured" };
  }

  const leads = quote.contact_id ? await dbFetch(`leads?id=eq.${quote.contact_id}&select=lead_name,lead_phone`) : null;
  const lead = leads?.[0];
  const phone = lead?.lead_phone;
  if (!phone) {
    return { quote_id: quote.id, status: "skipped", error: "No phone number on file for this lead" };
  }

  const leadName = lead?.lead_name || "";
  const bizName = business.business_name || "us";
  const body = DEFAULT_FOLLOWUP_MESSAGE
    .replace("{{name}}", leadName || "there")
    .replace("{{business}}", bizName);

  const result = await sendSms(phone, business.ai_phone_number, body);
  if (!result.ok) {
    return { quote_id: quote.id, status: "failed", error: result.error };
  }

  const updated = await dbFetch(
    `quotes?id=eq.${quote.id}&quote_followup_sent_at=is.null`,
    {
      method: "PATCH",
      body: JSON.stringify({ quote_followup_sent_at: new Date().toISOString() }),
    }
  );

  if (!updated || updated.length === 0) {
    return { quote_id: quote.id, status: "sent_but_race_on_flag" };
  }

  return { quote_id: quote.id, status: "sent" };
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
    // Candidate pool: any sent, un-followed-up, non-deleted quote. The
    // per-business day threshold is checked in processQuote since it
    // varies per business — can't be pushed into this filter.
    const quotes = await dbFetch(
      `quotes?status=eq.sent&sent_at=not.is.null&quote_followup_sent_at=is.null&deleted_at=is.null` +
      `&select=id,business_id,contact_id,sent_at`
    );

    if (!quotes || quotes.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const results = [];
    for (const quote of quotes) {
      try {
        results.push(await processQuote(quote));
      } catch (e: any) {
        console.error(`Failed quote ${quote.id}:`, e.message);
        results.push({ quote_id: quote.id, status: "error", error: e.message });
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    console.error("send-quote-followups error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});