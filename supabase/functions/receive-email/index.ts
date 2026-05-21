import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const OPENAI_API_KEY       = Deno.env.get("OPENAI_API_KEY")!;
const MAILGUN_API_KEY      = Deno.env.get("MAILGUN_API_KEY")!;
const MAILGUN_DOMAIN       = Deno.env.get("MAILGUN_DOMAIN")!; // mail.vantagecaretech.com
const NOTIFY_OWNER_WEBHOOK = Deno.env.get("NOTIFY_OWNER_WEBHOOK") ?? "";

// ── Send email via Mailgun ────────────────────────────────────────────────────
async function sendEmail(opts: {
  to: string;
  from: string;
  replyTo: string;
  subject: string;
  text: string;
}) {
  const creds = btoa(`api:${MAILGUN_API_KEY}`);
  const body  = new URLSearchParams({
    to:         opts.to,
    from:       opts.from,
    "h:Reply-To": opts.replyTo,
    subject:    opts.subject,
    text:       opts.text,
  });
  const res = await fetch(
    `https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`,
    {
      method: "POST",
      headers: { Authorization: `Basic ${creds}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    }
  );
  const json = await res.json();
  if (!res.ok) throw new Error(`Mailgun error: ${JSON.stringify(json)}`);
  return json;
}

// ── Parse multipart/form-data from Mailgun inbound ───────────────────────────
async function parseMailgunPayload(req: Request): Promise<Record<string, string>> {
  const contentType = req.headers.get("content-type") ?? "";
  const fields: Record<string, string> = {};

  if (contentType.includes("multipart/form-data")) {
    const formData = await req.formData();
    for (const [key, val] of formData.entries()) {
      if (typeof val === "string") fields[key] = val;
    }
  } else {
    // fallback: url-encoded
    const text = await req.text();
    for (const [k, v] of new URLSearchParams(text).entries()) {
      fields[k] = v;
    }
  }
  return fields;
}

// ── Extract sender name and email from "Name <email>" format ─────────────────
function parseSender(from: string): { name: string | null; email: string } {
  const match = from.match(/^(.+?)\s*<([^>]+)>$/);
  if (match) {
    return { name: match[1].trim().replace(/^"|"$/g, "") || null, email: match[2].trim().toLowerCase() };
  }
  return { name: null, email: from.trim().toLowerCase() };
}

// ── Extract first name ────────────────────────────────────────────────────────
function firstName(fullName: string): string {
  return fullName.trim().split(/\s+/)[0] ?? fullName.trim();
}

function looksLikeName(s: string): boolean {
  const t = s.trim();
  return t.length >= 2 && t.length <= 60 && /[a-zA-Z]/.test(t) && !/\d/.test(t);
}

function looksLikePhone(s: string): boolean {
  const digits = s.replace(/\D/g, "");
  return digits.length >= 10 && digits.length <= 15;
}

function looksLikeAddress(s: string): boolean {
  return /\d/.test(s) && s.trim().split(/\s+/).length >= 3;
}

// ── Clean subject for reply ───────────────────────────────────────────────────
function replySubject(subject: string): string {
  const clean = subject.replace(/^(re:\s*)+/i, "").trim();
  return `Re: ${clean}`;
}

// ── Find available booking slots ──────────────────────────────────────────────
async function findAvailableSlots(
  businessId: number,
  availability: Record<string, any>,
  slotDurationMinutes: number,
  existingAppointments: Array<{ start_date_time: string; end_date_time: string }>
): Promise<Array<{ label: string; start: string; end: string }>> {
  const slots: Array<{ label: string; start: string; end: string }> = [];
  const now        = new Date();
  const dayNames   = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"];
  const dayShort   = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  const monthShort = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  for (let d = 0; d < 14 && slots.length < 3; d++) {
    const date    = new Date(now);
    date.setDate(now.getDate() + d);
    const dayName = dayNames[date.getDay()];
    const dayConf = availability[dayName];
    if (!dayConf || !dayConf.enabled) continue;

    const [startH, startM] = (dayConf.start as string).split(":").map(Number);
    const [endH,   endM  ] = (dayConf.end   as string).split(":").map(Number);
    const blocks: Array<{ start: string; end: string }> = dayConf.blocks ?? [];

    let cursor = new Date(date);
    cursor.setHours(startH, startM, 0, 0);
    const dayEnd = new Date(date);
    dayEnd.setHours(endH, endM, 0, 0);

    while (cursor < dayEnd && slots.length < 3) {
      const slotStart = new Date(cursor);
      const slotEnd   = new Date(cursor);
      slotEnd.setMinutes(slotEnd.getMinutes() + slotDurationMinutes);
      if (slotEnd > dayEnd) break;

      // Must be at least 2 hours from now
      if (slotStart <= new Date(now.getTime() + 2 * 60 * 60 * 1000)) {
        cursor.setMinutes(cursor.getMinutes() + slotDurationMinutes);
        continue;
      }

      const blockedByConfig = blocks.some((b) => {
        const [bSH, bSM] = (b.start as string).split(":").map(Number);
        const [bEH, bEM] = (b.end   as string).split(":").map(Number);
        const bStart = new Date(date); bStart.setHours(bSH, bSM, 0, 0);
        const bEnd   = new Date(date); bEnd.setHours(bEH, bEM, 0, 0);
        return slotStart < bEnd && slotEnd > bStart;
      });

      const blockedByAppt = existingAppointments.some((a) => {
        const aStart = new Date(a.start_date_time);
        const aEnd   = new Date(a.end_date_time);
        return slotStart < aEnd && slotEnd > aStart;
      });

      if (!blockedByConfig && !blockedByAppt) {
        const dow = dayShort[slotStart.getDay()];
        const mon = monthShort[slotStart.getMonth()];
        const day = slotStart.getDate();
        const h   = slotStart.getHours();
        const m   = slotStart.getMinutes().toString().padStart(2, "0");
        const hr  = h === 0 ? 12 : h > 12 ? h - 12 : h;
        const per = h < 12 ? "AM" : "PM";
        slots.push({
          label: `${dow} ${mon} ${day} at ${hr}:${m} ${per}`,
          start: slotStart.toISOString(),
          end:   slotEnd.toISOString(),
        });
      }
      cursor.setMinutes(cursor.getMinutes() + slotDurationMinutes);
    }
  }
  return slots;
}

// ── Build AI system prompt ────────────────────────────────────────────────────
async function buildSystemPrompt(
  business: Record<string, any>,
  lead: Record<string, any> | null,
  contactName: string | null,
  collectingInfo: Record<string, any>
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
    business.address_line1, business.address_line2,
    business.city, business.state, business.zip_code,
  ].filter(Boolean).join(", ");

  const sections: string[] = [];

  sections.push(
    `You are ${business.ai_persona || "a helpful assistant"} representing ${business.business_name || "this business"}.`
  );
  if (business.industry)     sections.push(`Industry: ${business.industry}`);
  if (business.primary_goal) sections.push(`Your primary goal: ${business.primary_goal}`);

  const contactInfo = [
    business.business_phone  ? `Phone: ${business.business_phone}`      : "",
    business.business_email  ? `Email: ${business.business_email}`      : "",
    business.company_website ? `Website: ${business.company_website}`   : "",
    address                  ? `Address: ${address}`                    : "",
    business.booking_link    ? `Booking link: ${business.booking_link}` : "",
  ].filter(Boolean);
  if (contactInfo.length) sections.push(`BUSINESS CONTACT INFO:\n${contactInfo.join("\n")}`);

  if (business.services_and_pricing) sections.push(`SERVICES & PRICING:\n${business.services_and_pricing}`);
  if (knowledgeBase)                 sections.push(`KNOWLEDGE BASE:\n${knowledgeBase}`);
  if (business.company_faqs)         sections.push(`FREQUENTLY ASKED QUESTIONS:\n${business.company_faqs}`);

  const knownFirst = contactName ? firstName(contactName) : null;
  if (knownFirst) {
    sections.push(`CONTACT INFO:\nThe person's name is ${knownFirst}. Use their first name naturally during the conversation — not in every sentence, just where it feels natural.`);
  }
  if (lead?.lead_phone)   sections.push(`Their phone: ${lead.lead_phone}`);
  if (lead?.lead_address) sections.push(`Their address: ${lead.lead_address}`);

  if (business.forbidden_words) sections.push(`NEVER mention or discuss: ${business.forbidden_words}`);

  // Info collection state
  const waiting = collectingInfo.waiting_for;
  if (waiting === "name") {
    sections.push(`IMPORTANT: You just asked this person for their name. Their reply IS their name. Use it naturally and move on.`);
  } else if (waiting === "phone") {
    sections.push(`IMPORTANT: You just asked for their phone number. Their reply IS their phone number. Acknowledge it and continue.`);
  } else if (waiting === "address") {
    sections.push(`IMPORTANT: You just asked for their full address. Their reply IS their address. Acknowledge it and continue.`);
  }

  sections.push(`EMAIL RULES (strictly follow):
- This is email, so replies can be 2-4 sentences — professional but warm and conversational.
- Plain text only. No markdown, no bullet points, no HTML formatting.
- Never identify yourself as an AI unless directly asked. If asked, be honest.
- Sign off naturally — no formal signatures needed, keep it friendly.
- If you don't know something, say someone will follow up — never guess.
- If they seem upset or want a human, acknowledge warmly and say a team member will be in touch.
- When you have their name, use their first name naturally where appropriate.`);

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
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: systemPrompt },
        ...history.slice(-12),
        { role: "user", content: inboundMessage },
      ],
      max_tokens: 400,
      temperature: 0.65,
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`OpenAI error: ${JSON.stringify(json)}`);
  return json.choices?.[0]?.message?.content?.trim() ?? "";
}

// ── Detect booking intent ─────────────────────────────────────────────────────
async function detectIntent(message: string, history: Array<{ role: string; content: string }>): Promise<{
  wantsBooking: boolean;
  isPickingSlot: boolean;
  slotChoice: number | null;
}> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        {
          role: "system",
          content: `Analyze the message and history. Return ONLY valid JSON:
{
  "wantsBooking": boolean,
  "isPickingSlot": boolean,
  "slotChoice": number | null
}
isPickingSlot is true if they reply with 1, 2, or 3 to choose a time slot. No explanation. JSON only.`,
        },
        ...history.slice(-6),
        { role: "user", content: message },
      ],
      max_tokens: 60,
      temperature: 0,
    }),
  });
  const json = await res.json();
  try {
    return JSON.parse(json.choices?.[0]?.message?.content?.trim() ?? "{}");
  } catch {
    return { wantsBooking: false, isPickingSlot: false, slotChoice: null };
  }
}

// ── Main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  try {
    // Mailgun sends multipart/form-data
    const fields = await parseMailgunPayload(req);

    const rawFrom   = fields["from"]    ?? fields["sender"] ?? "";
    const rawTo     = fields["To"]      ?? fields["recipient"] ?? "";
    const subject   = fields["subject"] ?? fields["Subject"] ?? "(no subject)";
    const bodyPlain = fields["body-plain"] ?? fields["stripped-text"] ?? fields["body-html"] ?? "";
    const messageId = fields["Message-Id"] ?? fields["message-id"] ?? "";

    if (!rawFrom || !bodyPlain) {
      console.log("Missing from or body — skipping");
      return new Response("ok", { status: 200 });
    }

    const { name: senderName, email: senderEmail } = parseSender(rawFrom);
    console.log(`Inbound email | from:${senderEmail} | subject:"${subject}"`);

    // Ignore bounce/noreply addresses
    if (senderEmail.includes("noreply") || senderEmail.includes("no-reply") || senderEmail.includes("mailer-daemon")) {
      console.log("Ignoring automated sender");
      return new Response("ok", { status: 200 });
    }

    // ── 1. Match business by dedicated_email (the "To" address) ──────────────
    // rawTo looks like: leads+business-name@mail.vantagecaretech.com
    const { data: business } = await supabase
      .from("businesses")
      .select("*")
      .eq("dedicated_email", rawTo.trim().toLowerCase())
      .maybeSingle();

    if (!business) {
      // Try matching any business — fallback for catch-all routes
      const { data: anyBusiness } = await supabase
        .from("businesses")
        .select("*")
        .limit(1)
        .maybeSingle();
      if (!anyBusiness) {
        console.error(`No business found for: ${rawTo}`);
        return new Response("ok", { status: 200 });
      }
      console.log(`Fallback to business: ${anyBusiness.business_name}`);
    }

    const biz        = business!;
    const businessId = biz.id as number;

    // ── 2. Deduplicate by Message-Id ─────────────────────────────────────────
    if (messageId) {
      const { data: existing } = await supabase
        .from("messages")
        .select("id")
        .eq("twilio_sid", messageId) // reusing twilio_sid column as external_id
        .maybeSingle();
      if (existing) {
        console.log(`Duplicate Message-Id ${messageId} — skipping`);
        return new Response("ok", { status: 200 });
      }
    }

    // ── 3. Look up lead by email ──────────────────────────────────────────────
    const { data: lead } = await supabase
      .from("leads")
      .select("id, lead_name, lead_phone, lead_email, lead_address, lead_status, tags, notes, source")
      .eq("business_id", businessId)
      .eq("lead_email", senderEmail)
      .maybeSingle();

    const knownName: string | null = lead?.lead_name ?? senderName ?? null;

    // ── 4. Find or create conversation ────────────────────────────────────────
    let { data: conversation } = await supabase
      .from("conversations")
      .select("*")
      .eq("business_id", businessId)
      .eq("contact_email", senderEmail)
      .eq("channel", "email")
      .maybeSingle();

    const isNewConvo = !conversation;
    let collectingInfo: Record<string, any> = conversation?.collecting_info ?? {};

    if (!conversation) {
      const { data: newConvo, error: err } = await supabase
        .from("conversations")
        .insert({
          business_id:           businessId,
          contact_name:          knownName ?? senderEmail,
          contact_email:         senderEmail,
          contact_phone:         lead?.lead_phone ?? null,
          lead_id:               lead?.id ?? null,
          channel:               "email",
          status:                "open",
          ai_enabled:            true,
          last_message:          bodyPlain.slice(0, 200),
          last_message_at:       new Date().toISOString(),
          unread_count:          1,
          collecting_info:       {},
          pending_booking_slots: null,
        })
        .select()
        .maybeSingle();
      if (err) throw new Error(`Create conversation: ${err.message}`);
      conversation = newConvo;
    } else {
      await supabase.from("conversations").update({
        last_message:    bodyPlain.slice(0, 200),
        last_message_at: new Date().toISOString(),
        unread_count:    (conversation.unread_count ?? 0) + 1,
        status:          "open",
        contact_name:    conversation.contact_name !== senderEmail ? conversation.contact_name : (knownName ?? conversation.contact_name),
        lead_id:         conversation.lead_id ?? lead?.id ?? null,
      }).eq("id", conversation.id);
    }

    const conversationId = conversation!.id as number;

    // ── 5. Save inbound message ───────────────────────────────────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId,
      business_id:     businessId,
      body:            bodyPlain,
      direction:       "inbound",
      channel:         "email",
      status:          "delivered",
      sender_name:     knownName ?? senderEmail,
      twilio_sid:      messageId || null,
    });

    // ── 6. Check AI enabled ───────────────────────────────────────────────────
    if (!(conversation!.ai_enabled ?? true)) {
      console.log(`AI paused for convo ${conversationId}`);
      return new Response("ok", { status: 200 });
    }

    // ── 7. Load conversation history ──────────────────────────────────────────
    const { data: recentMessages } = await supabase
      .from("messages")
      .select("body, direction")
      .eq("conversation_id", conversationId)
      .order("created_at", { ascending: false })
      .limit(14);

    const history = (recentMessages ?? []).reverse().map((m: any) => ({
      role:    m.direction === "inbound" ? "user" : "assistant",
      content: m.body,
    }));

    // Determine from address for replies
    const replyFrom = biz.dedicated_email ?? `leads@${MAILGUN_DOMAIN}`;
    const replySubj = replySubject(subject);

    // ═════════════════════════════════════════════════════════════════════════
    //  STEP A: Capture info we were waiting for
    // ═════════════════════════════════════════════════════════════════════════
    let aiReply = "";
    let skipNormalFlow = false;

    if (collectingInfo.waiting_for === "name") {
      if (looksLikeName(bodyPlain)) {
        const capturedName = bodyPlain.trim().split(/\n/)[0].trim(); // first line only
        const first = firstName(capturedName);

        await supabase.from("conversations").update({
          contact_name:    capturedName,
          collecting_info: { ...collectingInfo, waiting_for: null, name_collected: true },
        }).eq("id", conversationId);

        if (lead) {
          await supabase.from("leads").update({ lead_name: capturedName }).eq("id", lead.id);
        } else {
          await supabase.from("leads").insert({
            business_id: businessId,
            lead_name:   capturedName,
            lead_email:  senderEmail,
            lead_status: "In Conversation",
          });
        }

        collectingInfo = { ...collectingInfo, waiting_for: null, name_collected: true };

        const systemPrompt = await buildSystemPrompt(biz, lead, capturedName, collectingInfo);
        aiReply = await generateAiReply(
          systemPrompt,
          history,
          `[SYSTEM: The person just told you their name is "${capturedName}". Greet them warmly by first name (${first}) and ask how you can help them today. 1-2 friendly sentences.]`
        );
        skipNormalFlow = true;
      }

    } else if (collectingInfo.waiting_for === "phone") {
      if (looksLikePhone(bodyPlain.replace(/\D/g, "").slice(0, 15))) {
        const capturedPhone = bodyPlain.trim().split(/\n/)[0].trim();
        const normalized    = "+" + capturedPhone.replace(/\D/g, "");

        await supabase.from("conversations").update({
          contact_phone:   normalized,
          collecting_info: { ...collectingInfo, waiting_for: null, phone_collected: true },
        }).eq("id", conversationId);

        if (lead) {
          await supabase.from("leads").update({ lead_phone: normalized }).eq("id", lead.id);
        }
        collectingInfo = { ...collectingInfo, waiting_for: null, phone_collected: true };
        // Fall through — will continue to address or slots

      }

    } else if (collectingInfo.waiting_for === "address") {
      if (looksLikeAddress(bodyPlain)) {
        const capturedAddress = bodyPlain.trim().split(/\n/).slice(0, 3).join(", ");

        await supabase.from("conversations").update({
          collecting_info: { ...collectingInfo, waiting_for: null, address_collected: true },
        }).eq("id", conversationId);

        if (lead) {
          await supabase.from("leads").update({ lead_address: capturedAddress }).eq("id", lead.id);
        }
        collectingInfo = { ...collectingInfo, waiting_for: null, address_collected: true };
        // Fall through — will now offer slots
      }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STEP B: Normal flow
    // ═════════════════════════════════════════════════════════════════════════

    if (!skipNormalFlow) {
      const currentName = collectingInfo.name_collected
        ? conversation!.contact_name
        : knownName;

      // ── B1: Don't know name yet — ask ────────────────────────────────────
      if (!currentName || currentName === senderEmail) {
        const bizName = biz.business_name ?? "us";
        aiReply = `Hi, thank you for reaching out to ${bizName}! I'd love to help you. Could I get your full name first?`;

        await supabase.from("conversations").update({
          collecting_info: { ...collectingInfo, waiting_for: "name" },
        }).eq("id", conversationId);

      } else {
        const first       = firstName(currentName);
        const pendingSlots = conversation!.pending_booking_slots as Array<{ label: string; start: string; end: string }> | null;
        const intent       = await detectIntent(bodyPlain, history);

        // ── B2a: Picking a slot ───────────────────────────────────────────
        if (pendingSlots && pendingSlots.length > 0 && intent.isPickingSlot && intent.slotChoice) {
          const chosenSlot = pendingSlots[intent.slotChoice - 1];

          if (!chosenSlot) {
            aiReply = `Sorry ${first}, that wasn't a valid choice. Please reply with 1, 2, or 3 to select one of the available times.`;
          } else {
            // Email channel needs: phone + address before booking
            const freshLead = (await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle()).data;
            const hasPhone   = freshLead?.lead_phone   || collectingInfo.phone_collected;
            const hasAddress = freshLead?.lead_address || collectingInfo.address_collected;

            if (!hasPhone) {
              aiReply = `Great choice, ${first}! Before I confirm, could I get your phone number?`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "phone", pending_slot_choice: intent.slotChoice },
              }).eq("id", conversationId);

            } else if (!hasAddress) {
              aiReply = `Almost done! Could I also get your full address, ${first}?`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "address", pending_slot_choice: intent.slotChoice },
              }).eq("id", conversationId);

            } else {
              // Book it!
              const { data: newAppt } = await supabase.from("appointments").insert({
                business_id:       businessId,
                appointment_name:  `Appointment – ${currentName}`,
                appointment_type:  "Consultation",
                status:            "New",
                start_date_time:   chosenSlot.start,
                end_date_time:     chosenSlot.end,
                lead_name:         currentName,
                lead_phone:        freshLead?.lead_phone ?? "",
                lead_email:        senderEmail,
                notes:             freshLead?.lead_address ? `Address: ${freshLead.lead_address}` : "",
                confirmation_sent: false,
              }).select().maybeSingle();

              await supabase.from("conversations").update({
                pending_booking_slots: null,
                collecting_info:       { ...collectingInfo, waiting_for: null },
              }).eq("id", conversationId);

              if (freshLead) {
                await supabase.from("leads").update({
                  lead_status:              "In Conversation",
                  converted_to_appointment: true,
                  appointment_scheduled_at: chosenSlot.start,
                }).eq("id", freshLead.id);
              }

              if (NOTIFY_OWNER_WEBHOOK) {
                fetch(NOTIFY_OWNER_WEBHOOK, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    appointment_id:   newAppt?.id,
                    lead_name:        currentName,
                    lead_email:       senderEmail,
                    lead_phone:       freshLead?.lead_phone ?? "",
                    lead_address:     freshLead?.lead_address ?? "",
                    appointment_time: chosenSlot.label,
                    business_id:      businessId,
                    channel:          "email",
                  }),
                }).catch((e) => console.error("Webhook error:", e));
              }

              aiReply = `You're all set, ${first}! I've booked you in for ${chosenSlot.label}. We look forward to seeing you — feel free to reply here if anything changes.`;
            }
          }

        // ── B2b: Wants to book ────────────────────────────────────────────
        } else if (intent.wantsBooking) {
          // Email channel: need phone + address before offering slots
          const hasPhone   = lead?.lead_phone   || collectingInfo.phone_collected;
          const hasAddress = lead?.lead_address || collectingInfo.address_collected;

          if (!hasPhone) {
            aiReply = `I'd be happy to help you schedule something, ${first}! Could I get your phone number first?`;
            await supabase.from("conversations").update({
              collecting_info: { ...collectingInfo, waiting_for: "phone", booking_requested: true },
            }).eq("id", conversationId);

          } else if (!hasAddress) {
            aiReply = `Thanks! And could I get your full address, ${first}?`;
            await supabase.from("conversations").update({
              collecting_info: { ...collectingInfo, waiting_for: "address", booking_requested: true },
            }).eq("id", conversationId);

          } else {
            // All info collected — find slots
            const { data: existingAppts } = await supabase
              .from("appointments")
              .select("start_date_time, end_date_time")
              .eq("business_id", businessId)
              .gte("start_date_time", new Date().toISOString());

            const availability   = biz.availability_hours ?? {};
            const slotDuration   = biz.slot_duration_minutes ?? 60;
            const availableSlots = await findAvailableSlots(businessId, availability, slotDuration, existingAppts ?? []);

            if (availableSlots.length === 0) {
              aiReply = `I'm sorry ${first}, I don't see any open slots in the next two weeks. I'll have someone from our team reach out to you directly to find a time that works.`;
            } else {
              await supabase.from("conversations").update({
                pending_booking_slots: availableSlots,
                collecting_info:       { ...collectingInfo, waiting_for: null },
              }).eq("id", conversationId);

              const slotList = availableSlots.map((s, i) => `${i + 1}) ${s.label}`).join("\n");
              aiReply = `Here are our next available times, ${first}:\n\n${slotList}\n\nJust reply with 1, 2, or 3 and I'll get you booked in.`;
            }
          }

        // ── B2c: Normal conversation ──────────────────────────────────────
        } else {
          // Check if mid-booking and they sent something else
          if (collectingInfo.booking_requested && !collectingInfo.waiting_for) {
            const hasPhone   = lead?.lead_phone   || collectingInfo.phone_collected;
            const hasAddress = lead?.lead_address || collectingInfo.address_collected;

            if (!hasPhone) {
              aiReply = `I just need your phone number to get that appointment set up for you, ${first}.`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "phone" },
              }).eq("id", conversationId);
              skipNormalFlow = true;
            } else if (!hasAddress) {
              aiReply = `And your full address, ${first}?`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "address" },
              }).eq("id", conversationId);
              skipNormalFlow = true;
            }
          }

          if (!aiReply) {
            const systemPrompt = await buildSystemPrompt(biz, lead, currentName, collectingInfo);
            aiReply = await generateAiReply(systemPrompt, history, bodyPlain);
          }
        }
      }
    }

    if (!aiReply) {
      console.error("Empty AI reply — skipping");
      return new Response("ok", { status: 200 });
    }

    console.log(`AI reply: "${aiReply.slice(0, 100)}..."`);

    // ── Send reply via Mailgun ────────────────────────────────────────────────
    await sendEmail({
      to:      senderEmail,
      from:    `${biz.business_name ?? "Support"} <${replyFrom}>`,
      replyTo: replyFrom,
      subject: replySubj,
      text:    aiReply,
    });

    // ── Save outbound message ─────────────────────────────────────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId,
      business_id:     businessId,
      body:            aiReply,
      direction:       "outbound",
      channel:         "email",
      status:          "delivered",
      sender_name:     "AI Assistant",
      sent_via_twiml:  true,
    });

    await supabase.from("conversations").update({
      last_message:    aiReply.slice(0, 200),
      last_message_at: new Date().toISOString(),
    }).eq("id", conversationId);

    // ── Fire new_lead automation ──────────────────────────────────────────────
    if (isNewConvo) {
      fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/run-automation`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization:  `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}`,
        },
        body: JSON.stringify({
          trigger_type: "new_lead",
          business_id:  businessId,
          payload: {
            lead_name: knownName ?? senderEmail,
            phone:     lead?.lead_phone ?? "",
            email:     senderEmail,
            lead_id:   lead?.id ?? null,
          },
        }),
      }).catch((e) => console.error("Automation error:", e));
    }

    return new Response("ok", { status: 200 });

  } catch (err) {
    console.error("receive-email error:", err);
    // Always return 200 to Mailgun so it doesn't retry infinitely
    return new Response("ok", { status: 200 });
  }
});