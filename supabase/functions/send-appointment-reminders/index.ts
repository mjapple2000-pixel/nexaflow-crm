// JB-SMS-01: Automated Appointment/Visit Reminders
// Cron-triggered (every 15 min), modeled on process-scheduled-automations'
// own inline-Twilio pattern (NOT the send-sms edge function, which is
// wired to messages/conversations rows a reminder doesn't have).
// Dedup via appointments.reminder_sent_at, compare-and-swap on write —
// same pattern as on_my_way_sent_at / reply_sent elsewhere in the system.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SUPABASE_SERVICE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? "";
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

// Reminder window: appointments starting within the next 24 hours.
const REMINDER_WINDOW_MS = 24 * 60 * 60 * 1000;

// Default copy — used because most businesses won't have a manually-built
// "Appointment Reminders" automation template to read from (that's an
// optional, separately-built thing). Same {{name}}/{{business}} tokens
// used by that manual template, for consistency.
const DEFAULT_REMINDER_MESSAGE =
  "Hi {{name}}, just a reminder about your upcoming appointment with {{business}} tomorrow. See you soon!";

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
// manual automation doing the same job. delay_relative_to_appointment
// lives as an item *inside* the actions array, not as a trigger_config
// key — confirmed against live data (Test Roofer's "Appointment
// Reminders" automation, id 17) before writing this.
async function hasManualReminderAutomation(businessId: number): Promise<boolean> {
  const containsFilter = encodeURIComponent(JSON.stringify([{ type: "delay_relative_to_appointment" }]));
  const rows = await dbFetch(
    `automations?business_id=eq.${businessId}&trigger_type=eq.appointment_booked&is_active=eq.true&deleted_at=is.null&actions=cs.${containsFilter}&select=id`
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

async function processAppointment(appointment: any): Promise<{ appointment_id: number; status: string; error?: string }> {
  const businessId = appointment.business_id;
  const phone = appointment.lead_phone;

  if (!phone) {
    return { appointment_id: appointment.id, status: "skipped", error: "No phone number on appointment" };
  }

  const businesses = await dbFetch(`businesses?id=eq.${businessId}&select=id,business_name,ai_phone_number,auto_appointment_reminders_enabled`);
  const business = businesses?.[0];
  if (!business) {
    return { appointment_id: appointment.id, status: "skipped", error: "Business not found" };
  }

  if (!business.auto_appointment_reminders_enabled) {
    return { appointment_id: appointment.id, status: "skipped", error: "Toggle off for this business" };
  }

  const allowed = await checkPlanFeature(businessId, "appointment_reminders");
  if (!allowed) {
    return { appointment_id: appointment.id, status: "skipped", error: "Not allowed on this business's plan" };
  }

  const hasManual = await hasManualReminderAutomation(businessId);
  if (hasManual) {
    return { appointment_id: appointment.id, status: "skipped", error: "Business already has a manual reminder automation" };
  }

  if (!business.ai_phone_number) {
    return { appointment_id: appointment.id, status: "skipped", error: "No Twilio number configured" };
  }

  const leadName = appointment.lead_name || "";
  const bizName = business.business_name || "us";
  const body = DEFAULT_REMINDER_MESSAGE
    .replace("{{name}}", leadName || "there")
    .replace("{{business}}", bizName);

  const result = await sendSms(phone, business.ai_phone_number, body);
  if (!result.ok) {
    return { appointment_id: appointment.id, status: "failed", error: result.error };
  }

  const updated = await dbFetch(
    `appointments?id=eq.${appointment.id}&reminder_sent_at=is.null`,
    {
      method: "PATCH",
      body: JSON.stringify({ reminder_sent_at: new Date().toISOString() }),
    }
  );

  if (!updated || updated.length === 0) {
    return { appointment_id: appointment.id, status: "sent_but_race_on_flag" };
  }

  return { appointment_id: appointment.id, status: "sent" };
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
    const now = new Date();
    const windowEnd = new Date(now.getTime() + REMINDER_WINDOW_MS);

    const appointments = await dbFetch(
      `appointments?deleted_at=is.null&canceled_at=is.null&reminder_sent_at=is.null` +
      `&start_date_time=gt.${now.toISOString()}&start_date_time=lte.${windowEnd.toISOString()}` +
      `&select=id,business_id,lead_name,lead_phone,start_date_time`
    );

    if (!appointments || appointments.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const results = [];
    for (const appt of appointments) {
      try {
        results.push(await processAppointment(appt));
      } catch (e: any) {
        console.error(`Failed appointment ${appt.id}:`, e.message);
        results.push({ appointment_id: appt.id, status: "error", error: e.message });
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    console.error("send-appointment-reminders error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});