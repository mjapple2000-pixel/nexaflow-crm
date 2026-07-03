const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;

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

async function executeAction(
  action: any,
  enrollment: any,
  automation: any,
  business: any,
  lead: any,
  appointment: any,
): Promise<{ action: string; status: string; error?: string }> {
  const type = action.type;
  const leadName = lead?.lead_name || "";
  const phone    = lead?.lead_phone || "";
  const bizName  = business?.business_name || "us";
  const fromNum  = business?.ai_phone_number || "";

  try {
    if (type === "send_sms") {
      if (!phone) return { action: type, status: "skipped", error: "No phone number" };
      if (!fromNum) return { action: type, status: "skipped", error: "No Twilio number configured" };
      const body = (action.message || "Hi {{name}}, a reminder from {{business}}.")
        .replace("{{name}}", leadName || "there")
        .replace("{{business}}", bizName);
      const result = await sendSms(phone, fromNum, body);
      return result.ok
        ? { action: type, status: "success" }
        : { action: type, status: "failed", error: result.error };
    }

    if (type === "send_review_request") {
      if (!phone) return { action: type, status: "skipped", error: "No phone number" };
      if (!fromNum) return { action: type, status: "skipped", error: "No Twilio number configured" };
      const platform = action.platform || "google";
      const reviewLink = platform === "facebook"
        ? (business?.facebook_review_link || "")
        : (business?.google_review_link || "");
      if (!reviewLink) return { action: type, status: "skipped", error: `No ${platform} review link configured` };
      const body = (action.message || "Hi {{name}}, thank you for choosing {{business}}! We'd love a quick review: {{review_link}}")
        .replace("{{name}}", leadName || "there")
        .replace("{{business}}", bizName)
        .replace("{{review_link}}", reviewLink);
      const result = await sendSms(phone, fromNum, body);
      return result.ok
        ? { action: type, status: "success" }
        : { action: type, status: "failed", error: result.error };
    }

    if (type === "notify_owner") {
      // Placeholder — notify_owner via Make webhook not wired in cron context yet
      console.log("notify_owner in scheduled context — skipping for now");
      return { action: type, status: "skipped", error: "notify_owner not yet wired in scheduled context" };
    }

    return { action: type, status: "skipped", error: `Action type '${type}' not supported in scheduled context` };

  } catch (e: any) {
    return { action: type, status: "failed", error: e.message };
  }
}

async function processEnrollment(enrollment: any): Promise<void> {
  const automationId  = enrollment.automation_id;
  const businessId    = enrollment.business_id;
  const leadId        = enrollment.lead_id;
  const appointmentId = enrollment.appointment_id;
  let   actionIndex   = enrollment.next_action_index;

  // Fetch automation
  const automations = await dbFetch(`automations?id=eq.${automationId}&select=*`);
  const automation  = automations?.[0];
  if (!automation) {
    console.error(`Automation ${automationId} not found — marking enrollment ${enrollment.id} complete`);
    await dbFetch(`automation_enrollments?id=eq.${enrollment.id}`, {
      method: "PATCH",
      body: JSON.stringify({ completed_at: new Date().toISOString(), status: "completed" }),
    });
    return;
  }

  const actions: any[] = automation.actions || [];

  // Fetch supporting data
  const businesses  = await dbFetch(`businesses?id=eq.${businessId}&select=*`);
  const business    = businesses?.[0] || {};
  const leads       = leadId ? await dbFetch(`leads?id=eq.${leadId}&select=*`) : null;
  const lead        = leads?.[0] || null;
  const appts       = appointmentId ? await dbFetch(`appointments?id=eq.${appointmentId}&select=*`) : null;
  const appointment = appts?.[0] || null;

  const actionsRun: any[] = [];

  // Walk actions starting from next_action_index
  // Skip the wait action at current index — it already fired, move to the action after it
  let startIndex = actionIndex + 1;

  for (let i = startIndex; i < actions.length; i++) {
    const action = actions[i];

    // Hit another wait — schedule next enrollment update and stop
    if (action.type === "wait_until" || action.type === "delay_relative_to_appointment") {
      let nextRunAt: string | null = null;

      if (action.type === "wait_until") {
        const delayMinutes = action.delay_minutes || 0;
        nextRunAt = new Date(Date.now() + delayMinutes * 60 * 1000).toISOString();
      }

      if (action.type === "delay_relative_to_appointment") {
        const startTime = appointment?.start_date_time;
        if (startTime) {
          const offsetMinutes = action.offset_minutes || 0;
          const runAt = new Date(new Date(startTime).getTime() + offsetMinutes * 60 * 1000);
          if (runAt.getTime() > Date.now()) {
            nextRunAt = runAt.toISOString();
          } else {
            // Past due — skip this wait and continue
            console.log(`Skipping past-due wait at index ${i} for enrollment ${enrollment.id}`);
            continue;
          }
        }
      }

      if (nextRunAt) {
        await dbFetch(`automation_enrollments?id=eq.${enrollment.id}`, {
          method: "PATCH",
          body: JSON.stringify({
            next_action_index: i,
            next_run_at: nextRunAt,
          }),
        });
        actionsRun.push({ action: action.type, status: "scheduled", next_run_at: nextRunAt });
        break;
      }
      continue;
    }

    // Execute action
    const result = await executeAction(action, enrollment, automation, business, lead, appointment);
    actionsRun.push({ ...result, action_index: i });

    // If this was the last action, complete the enrollment
    if (i === actions.length - 1) {
      await dbFetch(`automation_enrollments?id=eq.${enrollment.id}`, {
        method: "PATCH",
        body: JSON.stringify({ completed_at: new Date().toISOString(), status: "completed" }),
      });
    }
  }

  // If no actions were found after the wait (empty sequence), complete enrollment
  if (startIndex >= actions.length) {
    await dbFetch(`automation_enrollments?id=eq.${enrollment.id}`, {
      method: "PATCH",
      body: JSON.stringify({ completed_at: new Date().toISOString(), status: "completed" }),
    });
  }

  // Write log
  const anyFailed = actionsRun.some(a => a.status === "failed");
  const allFailed = actionsRun.length > 0 && actionsRun.every(a => a.status === "failed");
  const logStatus = allFailed ? "failed" : anyFailed ? "partial" : "success";

  await dbFetch("automation_logs", {
    method: "POST",
    body: JSON.stringify({
      automation_id:   automationId,
      business_id:     businessId,
      trigger_type:    automation.trigger_type,
      trigger_payload: {},
      actions_run:     actionsRun,
      lead_id:         leadId || null,
      appointment_id:  appointmentId || null,
      action_index:    startIndex,
      status:          logStatus,
    }),
  }).catch((e: any) => console.error("Log write failed:", e.message));
}

Deno.serve(async (_req) => {
  try {
    const now = new Date().toISOString();

    const enrollments = await dbFetch(
      `automation_enrollments?next_run_at=lte.${now}&completed_at=is.null&deleted_at=is.null&status=eq.active&select=*`
    );

    if (!enrollments || enrollments.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    console.log(`Processing ${enrollments.length} due enrollments`);

    const results: any[] = [];
    for (const enrollment of enrollments) {
      try {
        await processEnrollment(enrollment);
        results.push({ enrollment_id: enrollment.id, status: "processed" });
      } catch (e: any) {
        console.error(`Failed enrollment ${enrollment.id}:`, e.message);
        results.push({ enrollment_id: enrollment.id, status: "error", error: e.message });
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });

  } catch (e: any) {
    console.error("process-scheduled-automations error:", e.message);
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});