import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

async function sendSms(to: string, from: string, body: string) {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID")!;
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN")!;
  const credentials = btoa(`${accountSid}:${authToken}`);

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: "POST",
      headers: {
        "Authorization": `Basic ${credentials}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: to, From: from, Body: body }),
    }
  );

  const result = await response.json();
  console.log("SMS send result:", JSON.stringify(result));
}

Deno.serve(async (req) => {
  try {
    const formData = await req.formData();
    const callSid = formData.get("CallSid")?.toString() ?? "";
    const parentCallSid = formData.get("ParentCallSid")?.toString() ?? "";
    const dialCallStatus = formData.get("DialCallStatus")?.toString() ?? "";
    const callbackSource = formData.get("CallbackSource")?.toString() ?? "";
    const direction = formData.get("Direction")?.toString() ?? "";

    console.log("handle-call-status params:", Object.fromEntries(formData.entries()));

    // Only act on the Dial action callback — it's the only one with DialCallStatus
    if (!dialCallStatus) {
      console.log("Ignoring callback without DialCallStatus, source:", callbackSource, "direction:", direction);
      return new Response("ok", { status: 200 });
    }

    // The Dial action callback uses the parent inbound CallSid
    const lookupSid = dialCallStatus ? callSid : parentCallSid;

    // Statuses that mean the owner didn't answer
    const missedStatuses = ["no-answer", "busy", "failed", "canceled"];
    const wasMissed = missedStatuses.includes(dialCallStatus);

    // Fetch the call_log — use twilio_call_sid for deduplication
    const { data: callLog, error } = await supabase
      .from("call_logs")
      .select("id, business_id, contact_id, phone_number_from, phone_number_to, reply_sent")
      .eq("twilio_call_sid", lookupSid || callSid)
      .maybeSingle();

    if (error || !callLog) {
      console.error("call_log not found for CallSid:", callSid, error);
      return new Response("ok", { status: 200 });
    }

    // Update call status
    await supabase
      .from("call_logs")
      .update({
        call_status: wasMissed ? "missed" : "answered",
      })
      .eq("id", callLog.id);

    if (!wasMissed || callLog.reply_sent) {
      // Call was answered, or SMS already sent (race condition guard)
      return new Response("ok", { status: 200 });
    }

    // Atomically set reply_sent = true to prevent double-send
    const { data: updated, error: updateError } = await supabase
      .from("call_logs")
      .update({ reply_sent: true })
      .eq("id", callLog.id)
      .eq("reply_sent", false) // only succeeds if not already sent
      .select("id")
      .maybeSingle();

    if (updateError || !updated) {
      console.log("reply_sent already true — skipping SMS for callSid:", callSid);
      return new Response("ok", { status: 200 });
    }

    // Fetch business details for the SMS template
    const { data: business, error: bizError } = await supabase
      .from("businesses")
      .select("id, business_name, ai_phone_number, missed_call_text_message")
      .eq("id", callLog.business_id)
      .single();

    if (bizError) console.error("Business fetch error:", bizError);

    if (!business) {
      console.error("Business not found:", callLog.business_id);
      return new Response("ok", { status: 200 });
    }

    // Look up name from leads table first, fall back to contacts
    let firstName = "";
    const { data: lead } = await supabase
      .from("leads")
      .select("id, lead_name")
      .eq("business_id", callLog.business_id)
      .eq("lead_phone", callLog.phone_number_from)
      .maybeSingle();

    if (lead?.lead_name) {
      firstName = lead.lead_name.trim().split(/\s+/)[0] ?? "";
    } else if (callLog.contact_id) {
      const { data: contact } = await supabase
        .from("contacts")
        .select("first_name")
        .eq("id", callLog.contact_id)
        .maybeSingle();
      firstName = contact?.first_name ?? "";
    }

    // Build SMS body — use business template or fallback default
    const template = business.missed_call_text_message ||
      "Hey{first_name}, sorry we missed your call! How can we help?";

    const smsBody = template
      .replace("{first_name}", firstName ? ` ${firstName}` : "")
      .replace("{business_name}", business.business_name ?? "");

    // Send the SMS
    await sendSms(
      callLog.phone_number_from,
      business.ai_phone_number,
      smsBody
    );

    // Log to messages table so it appears in Conversations inbox
    // First find or create the conversation — key by lead_id when a lead is
    // known (the permanent identity), phone only as a fallback for unknown
    // callers. Ordered + limited to 1 so it's resilient even if duplicate
    // rows exist, instead of .maybeSingle() (which silently returns null on
    // multiple matches and would create yet another duplicate).
    let conversationId: number | null = null;

    const { data: existingConvoMatches } = lead?.id
      ? await supabase
          .from("conversations")
          .select("id")
          .eq("business_id", callLog.business_id)
          .eq("lead_id", lead.id)
          .order("last_message_at", { ascending: false })
          .limit(1)
      : await supabase
          .from("conversations")
          .select("id")
          .eq("business_id", callLog.business_id)
          .eq("contact_phone", callLog.phone_number_from)
          .order("last_message_at", { ascending: false })
          .limit(1);

    const existingConvo = existingConvoMatches?.[0] ?? null;

    if (existingConvo) {
      conversationId = existingConvo.id;
      await supabase.from("conversations").update({
        last_message:    smsBody,
        last_message_at: new Date().toISOString(),
        lead_id:         lead?.id ?? null,
      }).eq("id", existingConvo.id);
    } else {
      const { data: newConvo } = await supabase
        .from("conversations")
        .insert({
          business_id:     callLog.business_id,
          contact_phone:   callLog.phone_number_from,
          contact_id:      callLog.contact_id ?? null,
          contact_name:    firstName || callLog.phone_number_from,
          lead_id:         lead?.id ?? null,
          channel:         "sms",
          status:          "open",
          ai_enabled:      true,
          last_message:    smsBody,
          last_message_at: new Date().toISOString(),
          unread_count:    1,
          collecting_info: {},
        })
        .select("id")
        .single();
      conversationId = newConvo?.id ?? null;
    }

    if (conversationId) {
      await supabase.from("messages").insert({
        business_id: callLog.business_id,
        conversation_id: conversationId,
        body: smsBody,
        direction: "outbound",
        channel: "sms",
        status: "delivered",
        sender_name: "AI Assistant",
        sent_via_twiml: true,
      });
    }

    return new Response("ok", { status: 200 });
  } catch (err) {
    console.error("handle-call-status error:", err);
    return new Response("ok", { status: 200 });
  }
});