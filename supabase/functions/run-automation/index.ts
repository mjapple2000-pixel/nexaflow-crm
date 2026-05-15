import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;

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

async function runAction(action: any, payload: any, business: any): Promise<{ action: string; status: string; error?: string }> {
  const type = action.type;

  try {
    if (type === "send_sms") {
      const to = payload.phone || payload.lead_phone;
      const body = (action.message || "")
        .replace("{{name}}", payload.lead_name || "there")
        .replace("{{business}}", business.business_name || "us");
      if (!to) return { action: type, status: "skipped", error: "No phone number" };

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

    if (type === "send_email") {
      // Placeholder — wire up SendGrid/Resend later
      console.log("send_email action:", action, payload);
      return { action: type, status: "success" };
    }

    if (type === "add_tag") {
      const leadId = payload.lead_id;
      if (!leadId) return { action: type, status: "skipped", error: "No lead_id" };
      const tag = action.tag || "";
      // Fetch current tags
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

    if (type === "move_pipeline_stage") {
      const leadId = payload.lead_id;
      const stageId = action.stage_id;
      if (!leadId || !stageId) return { action: type, status: "skipped", error: "Missing lead_id or stage_id" };
      await dbFetch(`leads?id=eq.${leadId}`, {
        method: "PATCH",
        body: JSON.stringify({ pipeline_stage_id: stageId }),
      });
      return { action: type, status: "success" };
    }

    if (type === "notify_owner") {
      const email = business.business_email;
      const msg = (action.message || "An automation was triggered for {{name}}")
        .replace("{{name}}", payload.lead_name || "a contact")
        .replace("{{business}}", business.business_name || "");
      console.log(`notify_owner → ${email}: ${msg}`);
      // Wire up email later
      return { action: type, status: "success" };
    }

    return { action: type, status: "skipped", error: "Unknown action type" };
  } catch (e: any) {
    return { action: type, status: "failed", error: e.message };
  }
}

serve(async (req) => {
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

    // Fetch business info for templates
    const businesses = await dbFetch(`businesses?id=eq.${business_id}&select=*`);
    const business = businesses?.[0] || {};

    const results = [];

    for (const automation of automations) {
      const actions: any[] = automation.actions || [];
      const actionsRun = [];

      for (const action of actions) {
        const result = await runAction(action, payload, business);
        actionsRun.push(result);
      }

      const anyFailed = actionsRun.some(a => a.status === "failed");
      const allFailed = actionsRun.every(a => a.status === "failed");
      const status = allFailed ? "failed" : anyFailed ? "partial" : "success";

      // Log the run
      await dbFetch("automation_logs", {
        method: "POST",
        body: JSON.stringify({
          automation_id: automation.id,
          business_id,
          trigger_type,
          trigger_payload: payload,
          actions_run: actionsRun,
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