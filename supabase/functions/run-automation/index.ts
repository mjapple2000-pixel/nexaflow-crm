const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const NOTIFY_OWNER_WEBHOOK = Deno.env.get("NOTIFY_OWNER_WEBHOOK") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

// ── Build a human-readable subject + message per trigger type ─────────────────
function buildOwnerNotification(triggerType: string, payload: any, business: any): { subject: string; message: string } {
  const name = payload.lead_name || "Someone";
  const bizName = business.business_name || "your business";

  switch (triggerType) {
    case "new_lead":
      return {
        subject: `🔔 New Lead: ${name}`,
        message: `A new lead just came in for ${bizName}.`,
      };
    case "appointment_booked":
      return {
        subject: `📅 New Appointment: ${name}`,
        message: `${name} just booked an appointment with ${bizName}.`,
      };
    case "form_submitted":
      return {
        subject: `📋 New Form Submission: ${name}`,
        message: `${name} just submitted a form on ${bizName}.`,
      };
    case "status_changed":
      return {
        subject: `🔄 Lead Status Changed: ${name}`,
        message: `${name}'s status was changed to "${payload.new_status || "unknown"}" in ${bizName}.`,
      };
    case "job_form_completed":
      return {
        subject: `✅ Job Form Completed: ${payload.completed_by_name || "A technician"}`,
        message: `${payload.completed_by_name || "A technician"} just completed a job form${name !== "Someone" ? ` for ${name}` : ""} at ${bizName}.`,
      };
    default:
      return {
        subject: `⚡ Automation Triggered`,
        message: `An automation was triggered for ${name} in ${bizName}.`,
      };
  }
}

async function runAction(
  action: any,
  payload: any,
  business: any,
  triggerType: string
): Promise<{ action: string; status: string; error?: string }> {
  const type = action.type;

  try {
    // ── send_sms — sends to the lead ────────────────────────────────────────
    if (type === "send_sms") {
      const to = payload.phone || payload.lead_phone;
      const body = (action.message || "Hi {{name}}, thanks for reaching out to {{business}}! We'll be in touch shortly.")
        .replace("{{name}}", payload.lead_name || "there")
        .replace("{{business}}", business.business_name || "us");

      if (!to) return { action: type, status: "skipped", error: "No phone number in payload" };

      const from = business.ai_phone_number;
      if (!from) return { action: type, status: "skipped", error: "No Twilio number configured" };

      const twilioRes = await fetch(
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

      if (!twilioRes.ok) {
        const err = await twilioRes.text();
        return { action: type, status: "failed", error: err };
      }
      return { action: type, status: "success" };
    }

    // ── notify_owner — emails the business owner via Make ───────────────────
    if (type === "notify_owner") {
      if (!NOTIFY_OWNER_WEBHOOK) {
        return { action: type, status: "skipped", error: "No notify owner webhook configured" };
      }

      const ownerEmail = business.owner_email || business.business_email || business.admin_email;
      if (!ownerEmail) {
        return { action: type, status: "skipped", error: "No owner email configured" };
      }

      const { subject, message } = buildOwnerNotification(triggerType, payload, business);

      await fetch(NOTIFY_OWNER_WEBHOOK, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          to: ownerEmail,
          subject,
          message,
          lead_name:    payload.lead_name    || "",
          lead_email:   payload.email        || payload.lead_email || "",
          lead_phone:   payload.phone        || payload.lead_phone || "",
          business_name: business.business_name || "",
          trigger_type: triggerType,
        }),
      });

      return { action: type, status: "success" };
    }

    // ── send_email — placeholder, wire up later ─────────────────────────────
    if (type === "send_email") {
      console.log("send_email action (not yet implemented):", action, payload);
      return { action: type, status: "skipped", error: "send_email not yet implemented" };
    }

    // ── add_tag ─────────────────────────────────────────────────────────────
    if (type === "add_tag") {
      const leadId = payload.lead_id;
      if (!leadId) return { action: type, status: "skipped", error: "No lead_id" };
      const tag = action.tag || "";
      const leads = await dbFetch(`leads?id=eq.${leadId}&select=tags`);
      const current: string[] = leads?.[0]?.tags || [];
      if (!current.includes(tag)) {
        await dbFetch(`leads?id=eq.${leadId}`, {
          method: "PATCH",
          body: JSON.stringify({ tags: [...current, tag] }),
        });
      }
      return { action: type, status: "success" };
    }

    // ── move_pipeline_stage ─────────────────────────────────────────────────
    if (type === "move_pipeline_stage") {
      const leadId = payload.lead_id;
      const stageId = action.stage_id;
      if (!leadId || !stageId) {
        return { action: type, status: "skipped", error: "Missing lead_id or stage_id" };
      }
      await dbFetch(`leads?id=eq.${leadId}`, {
        method: "PATCH",
        body: JSON.stringify({ pipeline_stage_id: stageId }),
      });
      return { action: type, status: "success" };
    }

    // ── send_review_request ─────────────────────────────────────────────────
    if (type === "send_review_request") {
      const to = payload.phone || payload.lead_phone;
      if (!to) return { action: type, status: "skipped", error: "No phone number in payload" };

      const from = business.ai_phone_number;
      if (!from) return { action: type, status: "skipped", error: "No Twilio number configured" };

      const platform = action.platform || "google";
      const reviewLink = platform === "facebook"
        ? (business.facebook_review_link || "")
        : (business.google_review_link || "");

      if (!reviewLink) {
        return { action: type, status: "skipped", error: `No ${platform} review link configured for this business` };
      }

      const body = (action.message || "Hi {{name}}, thank you for choosing {{business}}! We'd love a quick review: {{review_link}}")
        .replace("{{name}}", payload.lead_name || "there")
        .replace("{{business}}", business.business_name || "us")
        .replace("{{review_link}}", reviewLink);

      const twilioRes = await fetch(
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

      if (!twilioRes.ok) {
        const err = await twilioRes.text();
        return { action: type, status: "failed", error: err };
      }

      // Log to automation_logs with result_status for review tracking
      await dbFetch("automation_logs", {
        method: "POST",
        body: JSON.stringify({
          automation_id: null,
          business_id: business.id,
          trigger_type: "send_review_request",
          trigger_payload: payload,
          actions_run: [{ action: type, platform, to }],
          status: "success",
          result_status: "sent",
        }),
      }).catch(() => {}); // non-blocking

      return { action: type, status: "success" };
    }

    // ── wait_until — fixed delay in minutes ─────────────────────────────────
    if (type === "wait_until") {
      // Handled by enrollment creation in main loop — skip here
      return { action: type, status: "scheduled" };
    }

    // ── delay_relative_to_appointment — offset from appointment start ────────
    if (type === "delay_relative_to_appointment") {
      // Handled by enrollment creation in main loop — skip here
      return { action: type, status: "scheduled" };
    }

    return { action: type, status: "skipped", error: "Unknown action type" };

  } catch (e: any) {
    return { action: type, status: "failed", error: e.message };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { trigger_type, business_id, payload } = await req.json();

    if (!trigger_type || !business_id) {
      return new Response(JSON.stringify({ error: "Missing trigger_type or business_id" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Fetch matching active automations
    const automations = await dbFetch(
      `automations?business_id=eq.${business_id}&trigger_type=eq.${trigger_type}&is_active=eq.true&select=*`
    );

    if (!automations || automations.length === 0) {
      return new Response(JSON.stringify({ ran: 0 }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Fetch business info
    const businesses = await dbFetch(`businesses?id=eq.${business_id}&select=*`);
    const business = businesses?.[0] || {};

    const results = [];

    for (const automation of automations) {
      const actions: any[] = automation.actions || [];
      const actionsRun = [];
      let enrollmentCreated = false;

      for (let i = 0; i < actions.length; i++) {
        const action = actions[i];

        // ── Hit a wait action — create enrollment and stop executing ──────────
        if (action.type === "wait_until" || action.type === "delay_relative_to_appointment") {
          let nextRunAt: string | null = null;

          if (action.type === "wait_until") {
            const delayMinutes = action.delay_minutes || 0;
            const runAt = new Date(Date.now() + delayMinutes * 60 * 1000);
            nextRunAt = runAt.toISOString();
          }

          if (action.type === "delay_relative_to_appointment") {
            const appointmentId = payload.appointment_id;
            if (appointmentId) {
              const appts = await dbFetch(`appointments?id=eq.${appointmentId}&select=start_date_time`);
              const startTime = appts?.[0]?.start_date_time;
              if (startTime) {
                const offsetMinutes = action.offset_minutes || 0; // negative = before
                const runAt = new Date(new Date(startTime).getTime() + offsetMinutes * 60 * 1000);
                // Skip if already in the past
                if (runAt.getTime() > Date.now()) {
                  nextRunAt = runAt.toISOString();
                } else {
                  console.log(`Skipping past-due delay step at index ${i} for automation ${automation.id}`);
                  continue;
                }
              }
            }
          }

          if (nextRunAt) {
            await dbFetch("automation_enrollments", {
              method: "POST",
              body: JSON.stringify({
                business_id,
                automation_id: automation.id,
                lead_id: payload.lead_id || null,
                appointment_id: payload.appointment_id || null,
                next_action_index: i,
                next_run_at: nextRunAt,
                status: "active",
                enrolled_at: new Date().toISOString(),
              }),
            });
            enrollmentCreated = true;
            actionsRun.push({ action: action.type, status: "scheduled", next_run_at: nextRunAt });
            break; // Stop — cron job picks up from here
          }
          continue;
        }

        // ── Normal action — execute immediately ───────────────────────────────
        const result = await runAction(action, payload, business, trigger_type);
        actionsRun.push(result);
      }

      const anyFailed = actionsRun.some(a => a.status === "failed");
      const allFailed = actionsRun.length > 0 && actionsRun.every(a => a.status === "failed");
      const status = enrollmentCreated ? "scheduled" : allFailed ? "failed" : anyFailed ? "partial" : "success";

      await dbFetch("automation_logs", {
        method: "POST",
        body: JSON.stringify({
          automation_id: automation.id,
          business_id,
          trigger_type,
          trigger_payload: payload,
          actions_run: actionsRun,
          lead_id: payload.lead_id || null,
          appointment_id: payload.appointment_id || null,
          status,
        }),
      });

      results.push({ automation_id: automation.id, status, actionsRun });
    }

    return new Response(JSON.stringify({ ran: results.length, results }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});