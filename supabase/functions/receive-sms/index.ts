import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const TWILIO_ACCOUNT_SID   = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN    = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const OPENAI_API_KEY       = Deno.env.get("OPENAI_API_KEY")!;
const NOTIFY_OWNER_WEBHOOK = Deno.env.get("NOTIFY_OWNER_WEBHOOK") ?? "";

// ── Always return empty TwiML ─────────────────────────────────────────────────
function twimlEmpty() {
  return new Response(
    `<?xml version='1.0' encoding='UTF-8'?><Response></Response>`,
    { headers: { "Content-Type": "text/xml" } }
  );
}

// ── Send SMS via Twilio REST ──────────────────────────────────────────────────
async function sendSms(to: string, from: string, body: string) {
  const url   = `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`;
  const creds = btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`);
  const res   = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Basic ${creds}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ To: to, From: from, Body: body }).toString(),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`Twilio error: ${JSON.stringify(json)}`);
  return json;
}

// ── Extract first name from a full name ───────────────────────────────────────
function firstName(fullName: string): string {
  return fullName.trim().split(/\s+/)[0] ?? fullName.trim();
}

// ── Check if a string looks like a real name (not a phone number or garbage) ──
function looksLikeName(s: string): boolean {
  const trimmed = s.trim();
  // Must be 2–60 chars, contain at least one letter, no digits
  return trimmed.length >= 2 && trimmed.length <= 60 && /[a-zA-Z]/.test(trimmed) && !/\d/.test(trimmed);
}

// ── Check if string looks like an email ──────────────────────────────────────
function looksLikeEmail(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim());
}

// ── Check if string looks like an address (has a number + street word) ────────
function looksLikeAddress(s: string): boolean {
  return /\d/.test(s) && s.trim().split(/\s+/).length >= 3;
}

// ── Find available booking slots ──────────────────────────────────────────────
async function findAvailableSlots(
  businessId: number,
  availability: Record<string, any>,
  slotDurationMinutes: number,
  existingAppointments: Array<{ start_date_time: string; end_date_time: string }>
): Promise<Array<{ label: string; start: string; end: string }>> {
  const slots: Array<{ label: string; start: string; end: string }> = [];
  const now       = new Date();
  const dayNames  = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"];
  const dayShort  = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  const monthShort= ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  // Look up to 14 days ahead
  for (let d = 0; d < 14 && slots.length < 3; d++) {
    const date    = new Date(now);
    date.setDate(now.getDate() + d);
    const dayName = dayNames[date.getDay()];
    const dayConf = availability[dayName];
    if (!dayConf || !dayConf.enabled) continue;

    const [startH, startM] = (dayConf.start as string).split(":").map(Number);
    const [endH,   endM  ] = (dayConf.end   as string).split(":").map(Number);
    const blocks: Array<{ start: string; end: string }> = dayConf.blocks ?? [];

    // Generate slots for this day
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

      // Check against blocked times for this day
      const blockedByDayConfig = blocks.some((b) => {
        const [bSH, bSM] = (b.start as string).split(":").map(Number);
        const [bEH, bEM] = (b.end   as string).split(":").map(Number);
        const bStart = new Date(date); bStart.setHours(bSH, bSM, 0, 0);
        const bEnd   = new Date(date); bEnd.setHours(bEH, bEM, 0, 0);
        return slotStart < bEnd && slotEnd > bStart;
      });

      // Check against existing appointments
      const blockedByAppt = existingAppointments.some((a) => {
        const aStart = new Date(a.start_date_time);
        const aEnd   = new Date(a.end_date_time);
        return slotStart < aEnd && slotEnd > aStart;
      });

      if (!blockedByDayConfig && !blockedByAppt) {
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

  // Contact context
  const knownName = contactName ? firstName(contactName) : null;
  if (knownName) {
sections.push(`CONTACT INFO:\nThe person's name is ${knownName}. IMPORTANT: You already know their name. Open your very first reply by greeting them as "${knownName}" — for example "Hi ${knownName}! How can I help you today?" Never say "Hey there" or a generic greeting when you already know their name.`);  }
  if (lead?.lead_email)   sections.push(`Their email: ${lead.lead_email}`);
  if (lead?.lead_address) sections.push(`Their address: ${lead.lead_address}`);

  if (business.forbidden_words) sections.push(`NEVER mention or discuss: ${business.forbidden_words}`);

  // Info collection state instructions
  const waiting = collectingInfo.waiting_for;
  if (waiting === "name") {
    sections.push(`IMPORTANT: You just asked this person for their name. Their reply IS their name. Extract it and use it naturally — do NOT ask for it again.`);
  } else if (waiting === "email") {
    sections.push(`IMPORTANT: You just asked this person for their email address. Their reply IS their email. Acknowledge it and continue.`);
  } else if (waiting === "address") {
    sections.push(`IMPORTANT: You just asked this person for their full address. Their reply IS their address. Acknowledge it and continue.`);
  }

  sections.push(`SMS RULES (strictly follow):
- Keep replies to 1-3 sentences. This is SMS — be brief and conversational.
- Plain text only. No markdown, no bullet points, no formatting.
- Never identify yourself as an AI unless directly asked. If asked, be honest.
- If you don't know the answer, say someone will follow up — never guess or make up information.
- If the contact seems upset or asks for a human, warmly acknowledge and say a team member will be in touch soon.
- When you have their name, use their first name naturally — but not in every single message, only where it feels natural.`);

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
      max_tokens: 300,
      temperature: 0.65,
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`OpenAI error: ${JSON.stringify(json)}`);
  return json.choices?.[0]?.message?.content?.trim() ?? "";
}

// ── Detect booking intent via AI ─────────────────────────────────────────────
async function detectIntent(message: string, history: Array<{ role: string; content: string }>): Promise<{
  wantsBooking: boolean;
  isPickingSlot: boolean; // replied with 1, 2, or 3
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
          content: `Analyze the user's message and conversation history. Return ONLY valid JSON with:
{
  "wantsBooking": boolean,  // true if they want to schedule/book/set up an appointment
  "isPickingSlot": boolean, // true if they're replying with 1, 2, or 3 to pick a time slot
  "slotChoice": number | null // 1, 2, or 3 if isPickingSlot is true, else null
}
No explanation. JSON only.`,
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
    const text = json.choices?.[0]?.message?.content?.trim() ?? "{}";
    return JSON.parse(text);
  } catch {
    return { wantsBooking: false, isPickingSlot: false, slotChoice: null };
  }
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

    // ── Deduplication ─────────────────────────────────────────────────────────
    if (messageSid) {
      const { data: existing } = await supabase
        .from("messages").select("id").eq("twilio_sid", messageSid).maybeSingle();
      if (existing) {
        console.log(`Duplicate MessageSid ${messageSid} — skipping`);
        return twimlEmpty();
      }
    }

    // ── 1. Find business ──────────────────────────────────────────────────────
    const { data: business } = await supabase
      .from("businesses").select("*").eq("ai_phone_number", to).maybeSingle();
    if (!business) { console.error(`No business for: ${to}`); return twimlEmpty(); }
    const businessId = business.id as number;

    // ── 2. Look up lead ───────────────────────────────────────────────────────
    const { data: lead } = await supabase
      .from("leads")
      .select("id, lead_name, lead_phone, lead_email, lead_address, lead_status, tags, notes, source")
      .eq("business_id", businessId)
      .eq("lead_phone", from)
      .maybeSingle();

    // ── 3. Find or create conversation ────────────────────────────────────────
    let { data: conversation } = await supabase
      .from("conversations")
      .select("*")
      .eq("business_id", businessId)
      .eq("contact_phone", from)
      .eq("channel", "sms")
      .maybeSingle();

    const isNewConvo = !conversation;

    // Determine what name we currently know
    const knownName: string | null = conversation?.contact_name && conversation.contact_name !== from
      ? conversation.contact_name
      : lead?.lead_name ?? null;

    // collecting_info tracks what we're waiting for: { waiting_for: "name"|"email"|"address"|null }
    let collectingInfo: Record<string, any> = conversation?.collecting_info ?? {};

    if (!conversation) {
      const { data: newConvo, error: err } = await supabase
        .from("conversations")
        .insert({
          business_id:     businessId,
          contact_name:    knownName ?? from,
          contact_phone:   from,
          contact_email:   lead?.lead_email ?? null,
          lead_id:         lead?.id ?? null,
          channel:         "sms",
          status:          "open",
          ai_enabled:      true,
          last_message:    body,
          last_message_at: new Date().toISOString(),
          unread_count:    1,
          collecting_info: {},
          pending_booking_slots: null,
        })
        .select().maybeSingle();
      if (err) throw new Error(`Create conversation: ${err.message}`);
      conversation = newConvo;
    } else {
      await supabase.from("conversations").update({
        last_message:    body,
        last_message_at: new Date().toISOString(),
        unread_count:    (conversation.unread_count ?? 0) + 1,
        status:          "open",
      }).eq("id", conversation.id);
    }

    const conversationId = conversation!.id as number;

    // ── 4. Save inbound message ───────────────────────────────────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId,
      business_id:     businessId,
      body:            body,
      direction:       "inbound",
      channel:         "sms",
      status:          "delivered",
      sender_name:     knownName ?? from,
      twilio_sid:      messageSid || null,
    });

    // ── 5. Check AI enabled ───────────────────────────────────────────────────
    if (!(conversation!.ai_enabled ?? true)) {
      console.log(`AI paused for convo ${conversationId}`);
      return twimlEmpty();
    }

    // ── 6. Load conversation history ──────────────────────────────────────────
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

    // ═════════════════════════════════════════════════════════════════════════
    //  STEP A: If we were waiting for a specific piece of info, capture it
    // ═════════════════════════════════════════════════════════════════════════
    let aiReply = "";
    let skipNormalFlow = false;

    if (collectingInfo.waiting_for === "name") {
      // Their reply is their name
      if (looksLikeName(body)) {
        const capturedName = body.trim();
        const first = firstName(capturedName);

        // Save to conversation and lead
        await supabase.from("conversations").update({
          contact_name:    capturedName,
          collecting_info: { ...collectingInfo, waiting_for: null, name_collected: true },
        }).eq("id", conversationId);

        // Upsert lead with name
        if (lead) {
          await supabase.from("leads").update({ lead_name: capturedName }).eq("id", lead.id);
        } else {
          await supabase.from("leads").insert({
            business_id: businessId,
            lead_name:   capturedName,
            lead_phone:  from,
            lead_status: "In Conversation",
          });
        }

        collectingInfo = { ...collectingInfo, waiting_for: null, name_collected: true };

        // Greet by first name and continue naturally
        const systemPrompt = await buildSystemPrompt(business, lead, capturedName, collectingInfo);
        aiReply = await generateAiReply(
          systemPrompt,
          history,
          `[SYSTEM: The user just told you their name is "${capturedName}". Greet them warmly by their first name (${first}) and ask how you can help them today. Keep it to one friendly sentence.]`
        );
        skipNormalFlow = true;
      }
      // If it doesn't look like a name, fall through and let AI handle it naturally

    } else if (collectingInfo.waiting_for === "email") {
      if (looksLikeEmail(body)) {
        const capturedEmail = body.trim().toLowerCase();
        await supabase.from("conversations").update({
          contact_email:   capturedEmail,
          collecting_info: { ...collectingInfo, waiting_for: null, email_collected: true },
        }).eq("id", conversationId);
        if (lead) {
          await supabase.from("leads").update({ lead_email: capturedEmail }).eq("id", lead.id);
        }
        collectingInfo = { ...collectingInfo, waiting_for: null, email_collected: true };

        // Immediately continue booking flow if booking was requested
        if (collectingInfo.booking_requested) {
          const currentName = conversation!.contact_name ?? knownName ?? from;
          const first = firstName(currentName);
          const hasAddress = lead?.lead_address || collectingInfo.address_collected;

          if (!hasAddress) {
            // Still need address — ask for it now
            aiReply = `Great! And could I get your full address, ${first}?`;
            await supabase.from("conversations").update({
              collecting_info: { ...collectingInfo, waiting_for: "address" },
            }).eq("id", conversationId);
            skipNormalFlow = true;
          } else {
            // Have everything — find and offer slots
            const { data: existingAppts } = await supabase
              .from("appointments")
              .select("start_date_time, end_date_time")
              .eq("business_id", businessId)
              .gte("start_date_time", new Date().toISOString());

            const availability   = business.availability_hours ?? {};
            const slotDuration   = business.slot_duration_minutes ?? 60;
            const availableSlots = await findAvailableSlots(businessId, availability, slotDuration, existingAppts ?? []);

            if (availableSlots.length === 0) {
              aiReply = `I'm sorry ${first}, I don't see any open slots in the next two weeks. I'll have someone from our team follow up with you directly.`;
            } else {
              await supabase.from("conversations").update({
                pending_booking_slots: availableSlots,
                collecting_info: { ...collectingInfo, waiting_for: null },
              }).eq("id", conversationId);
              const slotList = availableSlots.map((s, i) => `${i + 1}) ${s.label}`).join("  ");
              aiReply = `Perfect! Here are our next available times, ${first}: ${slotList}. Reply 1, 2, or 3 to book your spot.`;
            }
            skipNormalFlow = true;
          }
        }
      }
    }
      else if (collectingInfo.waiting_for === "address") {
      if (looksLikeAddress(body)) {
        const capturedAddress = body.trim();
        await supabase.from("conversations").update({
          collecting_info: { ...collectingInfo, waiting_for: null, address_collected: true },
        }).eq("id", conversationId);
        if (lead) {
          await supabase.from("leads").update({ lead_address: capturedAddress }).eq("id", lead.id);
        }
        collectingInfo = { ...collectingInfo, waiting_for: null, address_collected: true };

        // Immediately find and offer slots now that we have everything
        if (collectingInfo.booking_requested) {
          const currentName = conversation!.contact_name ?? knownName ?? from;
          const first = firstName(currentName);
          const { data: existingAppts } = await supabase
            .from("appointments")
            .select("start_date_time, end_date_time")
            .eq("business_id", businessId)
            .gte("start_date_time", new Date().toISOString());

          const availability   = business.availability_hours ?? {};
          const slotDuration   = business.slot_duration_minutes ?? 60;
          const availableSlots = await findAvailableSlots(businessId, availability, slotDuration, existingAppts ?? []);

          if (availableSlots.length === 0) {
            aiReply = `I'm sorry ${first}, I don't see any open slots in the next two weeks. I'll have someone from our team follow up with you directly.`;
          } else {
            await supabase.from("conversations").update({
              pending_booking_slots: availableSlots,
              collecting_info: { ...collectingInfo, waiting_for: null },
            }).eq("id", conversationId);
            const slotList = availableSlots.map((s, i) => `${i + 1}) ${s.label}`).join("  ");
            aiReply = `Perfect! Here are our next available times, ${first}: ${slotList}. Reply 1, 2, or 3 to book your spot.`;
          }
          skipNormalFlow = true;
        }
      }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  STEP B: Normal flow (if not already handled above)
    // ═════════════════════════════════════════════════════════════════════════

    if (!skipNormalFlow) {

      // ── B1: If we don't know their name yet, ask for it first ────────────
      const currentName = collectingInfo.name_collected
        ? conversation!.contact_name
        : knownName;

      if (!currentName || currentName === from) {
        // Don't know name — ask for it
        const businessName = business.business_name ?? "us";
        aiReply = `Hi! Thanks for reaching out to ${businessName}. I'd love to help you. Could I get your full name first?`;

        await supabase.from("conversations").update({
          collecting_info: { ...collectingInfo, waiting_for: "name" },
        }).eq("id", conversationId);

      } else {
        // ── B2: We know their name — proceed with intent detection ─────────
        const first = firstName(currentName);

        // Check for pending booking slot selection (1, 2, or 3)
        const pendingSlots = conversation!.pending_booking_slots as Array<{ label: string; start: string; end: string }> | null;

        const intent = await detectIntent(body, history);

        // ── B2a: Lead is picking a slot ──────────────────────────────────
        if (pendingSlots && pendingSlots.length > 0 && intent.isPickingSlot && intent.slotChoice) {
          const chosenSlot = pendingSlots[intent.slotChoice - 1];

          if (!chosenSlot) {
            aiReply = `Sorry ${first}, that wasn't a valid choice. Please reply 1, 2, or 3 to pick one of the available times.`;
          } else {
            // Check we still have all required info before booking
            const currentLead = lead ?? (await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_phone", from).maybeSingle()).data;
            const hasEmail   = currentLead?.lead_email   || collectingInfo.email_collected;
            const hasAddress = currentLead?.lead_address || collectingInfo.address_collected;

            if (!hasEmail) {
              // Still need email before booking
              aiReply = `Before I confirm that, could I get your email address, ${first}?`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "email", pending_slot_choice: intent.slotChoice },
              }).eq("id", conversationId);

            } else if (!hasAddress) {
              // Still need address
              aiReply = `Almost there! Could I also get your full address, ${first}?`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "address", pending_slot_choice: intent.slotChoice },
              }).eq("id", conversationId);

            } else {
              // Book it!
              const freshLead = (await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_phone", from).maybeSingle()).data;

              const { data: newAppt } = await supabase.from("appointments").insert({
                business_id:      businessId,
                appointment_name: `Appointment – ${currentName}`,
                appointment_type: "Consultation",
                status:           "New",
                start_date_time:  chosenSlot.start,
                end_date_time:    chosenSlot.end,
                lead_name:        currentName,
                lead_phone:       from,
                lead_email:       freshLead?.lead_email ?? "",
                notes:            freshLead?.lead_address ? `Address: ${freshLead.lead_address}` : "",
                confirmation_sent: false,
              }).select().maybeSingle();

              // Clear pending slots
              await supabase.from("conversations").update({
                pending_booking_slots: null,
                collecting_info: { ...collectingInfo, waiting_for: null },
              }).eq("id", conversationId);

              // Update lead
              if (freshLead) {
                await supabase.from("leads").update({
                  lead_status:              "In Conversation",
                  converted_to_appointment: true,
                  appointment_scheduled_at: chosenSlot.start,
                }).eq("id", freshLead.id);
              }

              // Notify owner via Make webhook
              if (NOTIFY_OWNER_WEBHOOK) {
                fetch(NOTIFY_OWNER_WEBHOOK, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    appointment_id:   newAppt?.id,
                    lead_name:        currentName,
                    lead_phone:       from,
                    lead_email:       freshLead?.lead_email ?? "",
                    lead_address:     freshLead?.lead_address ?? "",
                    appointment_time: chosenSlot.label,
                    business_id:      businessId,
                  }),
                }).catch((e) => console.error("Webhook error:", e));
              }

              aiReply = `You're all set, ${first}! I've booked you for ${chosenSlot.label}. We'll see you then — feel free to text us if anything changes.`;
            }
          }

        // ── B2b: Lead wants to book ───────────────────────────────────────
        } else if (intent.wantsBooking) {

          // Check what info we still need (SMS needs email + address)
          const hasEmail   = lead?.lead_email   || collectingInfo.email_collected;
          const hasAddress = lead?.lead_address || collectingInfo.address_collected;

          if (!hasEmail) {
            aiReply = `I'd be happy to help you schedule something, ${first}! Could I get your email address first?`;
            await supabase.from("conversations").update({
              collecting_info: { ...collectingInfo, waiting_for: "email", booking_requested: true },
            }).eq("id", conversationId);

          } else if (!hasAddress) {
            aiReply = `Great! And could I get your full address, ${first}?`;
            await supabase.from("conversations").update({
              collecting_info: { ...collectingInfo, waiting_for: "address", booking_requested: true },
            }).eq("id", conversationId);

          } else {
            // Have all info — find and offer slots
            const { data: existingAppts } = await supabase
              .from("appointments")
              .select("start_date_time, end_date_time")
              .eq("business_id", businessId)
              .gte("start_date_time", new Date().toISOString());

            const availability    = business.availability_hours ?? {};
            const slotDuration    = business.slot_duration_minutes ?? 60;
            const availableSlots  = await findAvailableSlots(businessId, availability, slotDuration, existingAppts ?? []);

            if (availableSlots.length === 0) {
              aiReply = `I'm sorry ${first}, I don't see any open slots in the next two weeks. I'll have someone from our team follow up with you directly to find a time that works.`;
            } else {
              await supabase.from("conversations").update({
                pending_booking_slots: availableSlots,
                collecting_info: { ...collectingInfo, waiting_for: null },
              }).eq("id", conversationId);

              const slotList = availableSlots.map((s, i) => `${i + 1}) ${s.label}`).join("  ");
              aiReply = `Here are our next available times, ${first}: ${slotList}. Reply 1, 2, or 3 to book your spot.`;
            }
          }

        // ── B2c: Normal conversation ──────────────────────────────────────
        } else {
          // Check if we were mid-booking-info-collection and they resumed
          if (collectingInfo.booking_requested && !collectingInfo.waiting_for) {
            const hasEmail   = lead?.lead_email   || collectingInfo.email_collected;
            const hasAddress = lead?.lead_address || collectingInfo.address_collected;

            if (!hasEmail) {
              aiReply = `I just need your email address to get that appointment set up for you, ${first}.`;
              await supabase.from("conversations").update({
                collecting_info: { ...collectingInfo, waiting_for: "email" },
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

          if (!skipNormalFlow || !aiReply) {
            const systemPrompt = await buildSystemPrompt(business, lead, currentName, collectingInfo);
            aiReply = await generateAiReply(systemPrompt, history, body);
          }
        }
      }
    }

    if (!aiReply) {
      console.error("Empty AI reply — skipping send");
      return twimlEmpty();
    }

    console.log(`AI reply: "${aiReply}"`);

    // ── Send SMS ──────────────────────────────────────────────────────────────
    await sendSms(from, to, aiReply);

    // ── Save outbound message ─────────────────────────────────────────────────
    const currentDisplayName = collectingInfo.name_collected
      ? conversation!.contact_name
      : (knownName ?? from);

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

    await supabase.from("conversations").update({
      last_message:    aiReply,
      last_message_at: new Date().toISOString(),
    }).eq("id", conversationId);

    // ── Fire new_lead automation on first contact ─────────────────────────────
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
          payload: { lead_name: knownName ?? from, phone: from, email: lead?.lead_email ?? "", lead_id: lead?.id ?? null },
        }),
      }).catch((e) => console.error("Automation error:", e));
    }

    return twimlEmpty();

  } catch (err) {
    console.error("receive-sms error:", err);
    return twimlEmpty();
  }
});