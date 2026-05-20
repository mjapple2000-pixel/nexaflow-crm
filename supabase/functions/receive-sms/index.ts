import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN  = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const OPENAI_API_KEY     = Deno.env.get("OPENAI_API_KEY")!;

// ── Always return empty TwiML — we send via REST API instead ─────────────────
function twimlEmpty() {
  return new Response(
    `<?xml version='1.0' encoding='UTF-8'?><Response></Response>`,
    { headers: { "Content-Type": "text/xml" } }
  );
}

// ── Send SMS via Twilio REST API ──────────────────────────────────────────────
async function sendSms(to: string, from: string, body: string) {
  const url   = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`;
  const creds = btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`);
  const res   = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Basic ${creds}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ To: to, From: from, Body: body }).toString(),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`Twilio error: ${JSON.stringify(json)}`);
  return json;
}

// ── Build rich AI system prompt ───────────────────────────────────────────────
async function buildSystemPrompt(
  business: Record<string, any>,
  lead: Record<string, any> | null
): Promise<string> {

  const { data: kbEntries } = await supabase
    .from("knowledge_base")
    .select("title, short_answer, content, category")
    .eq("business_id", business.id)
    .eq("is_active", true)
    .order("sort_order", { ascending: true });

  const knowledgeBase = (kbEntries ?? [])
    .map((e: any) => `[${e.category}] ${e.title}: ${e.short_answer || e.content || ""}`)
    .join("\n");

  const address = [
    business.address_line1,
    business.address_line2,
    business.city,
    business.state,
    business.zip_code,
  ].filter(Boolean).join(", ");

  let leadContext = "";
  if (lead) {
    const parts = [
      lead.lead_name   ? `Contact name: ${lead.lead_name}`   : "",
      lead.lead_email  ? `Email: ${lead.lead_email}`         : "",
      lead.lead_status ? `Status: ${lead.lead_status}`       : "",
      lead.tags        ? `Tags: ${lead.tags}`                : "",
      lead.notes       ? `Notes: ${lead.notes}`              : "",
      lead.source      ? `Lead source: ${lead.source}`       : "",
    ].filter(Boolean);
    if (parts.length) leadContext = `CONTACT CONTEXT:\n${parts.join("\n")}`;
  }

  const sections: string[] = [];

  sections.push(
    `You are ${business.ai_persona || "a helpful assistant"} representing ${business.business_name || "this business"}.`
  );
  if (business.industry)      sections.push(`Industry: ${business.industry}`);
  if (business.primary_goal)  sections.push(`Your primary goal: ${business.primary_goal}`);

  const contactInfo = [
    business.business_phone  ? `Phone: ${business.business_phone}`    : "",
    business.business_email  ? `Email: ${business.business_email}`    : "",
    business.company_website ? `Website: ${business.company_website}` : "",
    address                  ? `Address: ${address}`                  : "",
    business.booking_link    ? `Booking link: ${business.booking_link}` : "",
  ].filter(Boolean);
  if (contactInfo.length) sections.push(`BUSINESS CONTACT INFO:\n${contactInfo.join("\n")}`);

  if (business.services_and_pricing) sections.push(`SERVICES & PRICING:\n${business.services_and_pricing}`);
  if (knowledgeBase)                 sections.push(`KNOWLEDGE BASE:\n${knowledgeBase}`);
  if (business.company_faqs)         sections.push(`FREQUENTLY ASKED QUESTIONS:\n${business.company_faqs}`);
  if (leadContext)                   sections.push(leadContext);
  if (business.forbidden_words)      sections.push(`NEVER mention or discuss: ${business.forbidden_words}`);

  sections.push(
    business.booking_link
      ? `When someone wants to book, send them this link: ${business.booking_link}. Or collect their preferred date/time and let them know someone will confirm.`
      : `When someone wants to book, collect their preferred date/time and let them know someone will confirm shortly.`
  );

  sections.push(
    `SMS RULES (strictly follow):
- Keep replies to 1-3 sentences. This is SMS — be brief and conversational.
- Plain text only. No markdown, no bullet points, no formatting.
- Never identify yourself as an AI unless directly asked. If asked, be honest.
- If you don't know the answer, say someone will follow up — never guess or make up information.
- If the contact seems upset or asks for a human, warmly acknowledge them and say a team member will be in touch soon.`
  );

  return sections.join("\n\n");
}

// ── Generate AI reply ─────────────────────────────────────────────────────────
async function generateAiReply(
  systemPrompt: string,
  history: Array<{ role: string; content: string }>,
  inboundMessage: string
): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: systemPrompt },
        ...history.slice(-12),
        { role: "user", content: inboundMessage },
      ],
      max_tokens: 300,
      temperature: 0.65,
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`OpenAI error: ${JSON.stringify(json)}`);
  return json.choices?.[0]?.message?.content?.trim() ?? "";
}

// ── Main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  try {
    const params     = new URLSearchParams(await req.text());
    const from       = params.get("From")       ?? "";
    const to         = params.get("To")         ?? "";
    const body       = params.get("Body")       ?? "";
    const messageSid = params.get("MessageSid") ?? "";

    if (!from || !body) return twimlEmpty();

    console.log(`Inbound SMS | sid:${messageSid} from:${from} | "${body}"`);

    // ── DEDUPLICATION: if we've already processed this exact Twilio message, stop ──
    if (messageSid) {
      const { data: existing } = await supabase
        .from("messages")
        .select("id")
        .eq("twilio_sid", messageSid)
        .maybeSingle();

      if (existing) {
        console.log(`Duplicate MessageSid ${messageSid} — already processed, skipping`);
        return twimlEmpty();
      }
    }

    // ── 1. Find business by Twilio number ─────────────────────────────────────
    const { data: business } = await supabase
      .from("businesses")
      .select("*")
      .eq("ai_phone_number", to)
      .maybeSingle();

    if (!business) {
      console.error(`No business for number: ${to}`);
      return twimlEmpty();
    }

    const businessId = business.id as number;

    // ── 2. Look up lead ───────────────────────────────────────────────────────
    const { data: lead } = await supabase
      .from("leads")
      .select("id, lead_name, lead_email, lead_phone, lead_status, tags, notes, source")
      .eq("business_id", businessId)
      .eq("lead_phone", from)
      .maybeSingle();

    const contactName  = lead?.lead_name  ?? from;
    const contactEmail = lead?.lead_email ?? null;

    // ── 3. Find or create conversation ────────────────────────────────────────
    let { data: conversation } = await supabase
      .from("conversations")
      .select("*")
      .eq("business_id", businessId)
      .eq("contact_phone", from)
      .eq("channel", "sms")
      .maybeSingle();

    const isNewConvo = !conversation;

    if (!conversation) {
      const { data: newConvo, error: err } = await supabase
        .from("conversations")
        .insert({
          business_id:     businessId,
          contact_name:    contactName,
          contact_phone:   from,
          contact_email:   contactEmail,
          lead_id:         lead?.id ?? null,
          channel:         "sms",
          status:          "open",
          ai_enabled:      true,
          last_message:    body,
          last_message_at: new Date().toISOString(),
          unread_count:    1,
        })
        .select()
        .maybeSingle();

      if (err) throw new Error(`Create conversation: ${err.message}`);
      conversation = newConvo;
    } else {
      await supabase
        .from("conversations")
        .update({
          last_message:    body,
          last_message_at: new Date().toISOString(),
          unread_count:    (conversation.unread_count ?? 0) + 1,
          status:          "open",
          contact_name:    conversation.contact_name  || contactName,
          contact_email:   conversation.contact_email || contactEmail,
          lead_id:         conversation.lead_id ?? lead?.id ?? null,
        })
        .eq("id", conversation.id);
    }

    const conversationId = conversation!.id as number;

    // ── 4. Save inbound message (with MessageSid for dedup) ───────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId,
      business_id:     businessId,
      body:            body,
      direction:       "inbound",
      channel:         "sms",
      status:          "delivered",
      sender_name:     contactName,
      twilio_sid:      messageSid || null,
    });

    // ── 5. Check AI enabled ───────────────────────────────────────────────────
    const aiEnabled = conversation!.ai_enabled ?? true;
    if (!aiEnabled) {
      console.log(`AI paused for convo ${conversationId}`);
      return twimlEmpty();
    }

    // ── 6. Load conversation history ──────────────────────────────────────────
    const { data: recentMessages } = await supabase
      .from("messages")
      .select("body, direction")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false })
      .limit(12);

    const history = (recentMessages ?? [])
      .reverse()
      .map((m: any) => ({
        role:    m.direction === "inbound" ? "user" : "assistant",
        content: m.body,
      }));

    // ── 7. Build prompt + generate reply ─────────────────────────────────────
    const systemPrompt = await buildSystemPrompt(business, lead);
    const aiReply      = await generateAiReply(systemPrompt, history, body);

    if (!aiReply) {
      console.error("Empty AI reply");
      return twimlEmpty();
    }

    console.log(`AI reply: "${aiReply}"`);

    // ── 8. Send via Twilio REST API (single send, controlled) ─────────────────
    await sendSms(from, to, aiReply);

    // ── 9. Save outbound AI message ───────────────────────────────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId,
      business_id:     businessId,
      body:            aiReply,
      direction:       "outbound",
      channel:         "sms",
      status:          "delivered",
      sender_name:     "AI Assistant",
      sent_via_twiml:  true,
    });

    // ── 10. Update conversation last message ──────────────────────────────────
    await supabase
      .from("conversations")
      .update({
        last_message:    aiReply,
        last_message_at: new Date().toISOString(),
      })
      .eq("id", conversationId);

    // ── 11. Fire new_lead automation (fire and forget) ────────────────────────
    if (isNewConvo) {
      fetch(
        `${Deno.env.get("SUPABASE_URL")}/functions/v1/run-automation`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}`,
          },
          body: JSON.stringify({
            trigger_type: "new_lead",
            business_id:  businessId,
            payload: {
              lead_name: contactName,
              phone:     from,
              email:     contactEmail ?? "",
              lead_id:   lead?.id ?? null,
            },
          }),
        }
      ).catch((e) => console.error("Automation error:", e));
    }

    // ── Always return empty TwiML — reply already sent via REST above ─────────
    return twimlEmpty();

  } catch (err) {
    console.error("receive-sms error:", err);
    return twimlEmpty();
  }
});