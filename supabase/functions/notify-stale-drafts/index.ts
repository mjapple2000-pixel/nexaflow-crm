import { createClient } from "npm:@supabase/supabase-js@2";

const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN") ?? "";
const MAILGUN_API_KEY = Deno.env.get("MAILGUN_API_KEY") ?? "";
const MAILGUN_DOMAIN = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKeys.nexaflow_service_role_2026_08 ?? ""
);

// How long a draft can sit unreviewed before the business gets pinged.
// Mike's call (9/12): 1 hour — matches a normal "we'll get back to you
// today" email expectation, vs. the original spec's 4-hour suggestion.
const STALE_CUTOFF_MS = 60 * 60 * 1000;

async function sendSms(to: string, from: string, body: string): Promise<boolean> {
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ To: to, From: from, Body: body }).toString(),
  });
  if (!res.ok) {
    console.error("notify-stale-drafts: Twilio send failed:", await res.text());
    return false;
  }
  return true;
}

async function sendEmail(to: string, businessName: string, body: string): Promise<boolean> {
  const mgForm = new URLSearchParams();
  mgForm.append("from", `NexaFlow <no-reply@${MAILGUN_DOMAIN}>`);
  mgForm.append("to", to);
  mgForm.append("subject", `${businessName}: AI email drafts waiting for review`);
  mgForm.append("html", `<p>${body}</p>`);
  const res = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: mgForm.toString(),
  });
  if (!res.ok) {
    console.error("notify-stale-drafts: Mailgun send failed:", await res.text());
    return false;
  }
  return true;
}

Deno.serve(async (req) => {
  // Shared-secret check — triggered by pg_cron, not a logged-in user.
  // Same pattern as process-due-milestones / process-scheduled-automations.
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }

  try {
    // Grouped client-side by business below so a business with several
    // stale drafts gets ONE combined ping, not one notification per draft.
    const { data: staleMessages, error: queryErr } = await supabase
      .from("messages")
      .select("id, business_id")
      .eq("status", "pending_review")
      .is("stale_notified_at", null)
      .lt("created_at", new Date(Date.now() - STALE_CUTOFF_MS).toISOString());

    if (queryErr) throw queryErr;
    if (!staleMessages || staleMessages.length === 0) {
      return new Response(JSON.stringify({ notified_businesses: 0 }), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    }

    const byBusiness = new Map<number, number[]>();
    for (const m of staleMessages) {
      const list = byBusiness.get(m.business_id) ?? [];
      list.push(m.id);
      byBusiness.set(m.business_id, list);
    }

    const results: Array<Record<string, unknown>> = [];

    for (const [businessId, messageIds] of byBusiness.entries()) {
      const { data: biz } = await supabase
        .from("businesses")
        .select("business_name, owner_phone, owner_email, ai_phone_number, draft_alert_sms_enabled, draft_alert_email_enabled, draft_alert_phone, draft_alert_email")
        .eq("id", businessId)
        .maybeSingle();

      if (!biz) {
        results.push({ business_id: businessId, status: "skipped", reason: "business not found" });
        continue;
      }

      const count = messageIds.length;
      const plural = count === 1 ? "draft is" : "drafts are";
      const text = `You have ${count} AI email ${plural} waiting for review in NexaFlow. Log in to approve, edit, or discard.`;

      // Both channels fire independently by default — this is a one-way
      // notice with nothing to reply to, so redundancy across channels is
      // pure upside if one gets missed. draft_alert_phone/email let this
      // route to someone other than the owner (e.g. an office manager)
      // without touching owner_phone/owner_email, which are used
      // elsewhere for owner-specific purposes.
      const smsEnabled = biz.draft_alert_sms_enabled ?? true;
      const emailEnabled = biz.draft_alert_email_enabled ?? true;
      const alertPhone = biz.draft_alert_phone || biz.owner_phone;
      const alertEmail = biz.draft_alert_email || biz.owner_email;

      let smsSent = false;
      let emailSent = false;
      if (smsEnabled && alertPhone && biz.ai_phone_number) {
        smsSent = await sendSms(alertPhone, biz.ai_phone_number, text);
      }
      if (emailEnabled && alertEmail) {
        emailSent = await sendEmail(alertEmail, biz.business_name ?? "NexaFlow", text);
      }

      if (smsSent || emailSent) {
        await supabase.from("messages").update({ stale_notified_at: new Date().toISOString() }).in("id", messageIds);
        results.push({ business_id: businessId, status: "notified", count, via: { sms: smsSent, email: emailSent } });
      } else {
        results.push({ business_id: businessId, status: "no_contact_method", count });
      }
    }

    return new Response(JSON.stringify({ notified_businesses: results.length, results }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("notify-stale-drafts error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});