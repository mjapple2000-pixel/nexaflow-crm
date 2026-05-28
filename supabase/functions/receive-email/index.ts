import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const OPENAI_API_KEY       = Deno.env.get("OPENAI_API_KEY")!;
const MAILGUN_API_KEY      = Deno.env.get("MAILGUN_API_KEY")!;
const MAILGUN_DOMAIN       = Deno.env.get("MAILGUN_DOMAIN")!;
const NOTIFY_OWNER_WEBHOOK = Deno.env.get("NOTIFY_OWNER_WEBHOOK") ?? "";

// ── Send email via Mailgun ────────────────────────────────────────────────────
async function sendEmail(opts: { to: string; from: string; replyTo: string; subject: string; text: string }) {
  const creds = btoa(`api:${MAILGUN_API_KEY}`);
  const body  = new URLSearchParams({
    to: opts.to, from: opts.from, "h:Reply-To": opts.replyTo, subject: opts.subject, text: opts.text,
  });
  const res = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
    method: "POST",
    headers: { Authorization: `Basic ${creds}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
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
    const text = await req.text();
    for (const [k, v] of new URLSearchParams(text).entries()) fields[k] = v;
  }
  return fields;
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function parseSender(from: string): { name: string | null; email: string } {
  const match = from.match(/^(.+?)\s*<([^>]+)>$/);
  if (match) return { name: match[1].trim().replace(/^"|"$/g, "") || null, email: match[2].trim().toLowerCase() };
  return { name: null, email: from.trim().toLowerCase() };
}

function firstName(fullName: string): string {
  return fullName.trim().split(/\s+/)[0] ?? fullName.trim();
}

function hasLastName(fullName: string): boolean {
  return fullName.trim().split(/\s+/).length >= 2;
}

function looksLikePhone(s: string): boolean {
  const digits = s.replace(/\D/g, "");
  return digits.length >= 10 && digits.length <= 15;
}

function looksLikeAddress(s: string): boolean {
  return /\d/.test(s) && s.trim().split(/\s+/).length >= 3;
}

function replySubject(subject: string): string {
  return `Re: ${subject.replace(/^(re:\s*)+/i, "").trim()}`;
}

// ── Strip quoted email reply chains ──────────────────────────────────────────
function stripQuotedText(body: string): string {
  const lines = body.split("\n");
  const out: string[] = [];
  for (const line of lines) {
    const t = line.trim();
    if (t.startsWith(">")) break;
    if (/^on .{10,200} wrote:$/i.test(t)) break;
    if (/^-{3,}\s*original message\s*-{3,}$/i.test(t)) break;
    if (/^from:\s+\S+@/i.test(t) && out.length > 0) break;
    out.push(line);
  }
  return out.join("\n").trim();
}

// ── Use AI to extract a name from any natural reply ──────────────────────────
// Returns the name string or null if no name found
async function extractNameFromMessage(message: string, suggestedName: string | null): Promise<string | null> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [{
        role: "system",
        content: `Extract a person's name from their message. Return ONLY the name (e.g. "Michael Johnson") or "null" if no name is present or confirmed.
Rules:
- If they say "yes", "yep", "correct", "that's me", "sure" etc AND there is a suggested name, return the suggested name.
- If they give their name directly (e.g. "It's Michael", "My name is Sarah Jones", "Michael App"), extract just the name.
- If they say something unrelated to a name, return "null".
- Never return anything except a name or the word null.
${suggestedName ? `Suggested name to confirm: "${suggestedName}"` : ""}`,
      }, {
        role: "user",
        content: message,
      }],
      max_tokens: 20,
      temperature: 0,
    }),
  });
  const json = await res.json();
  const result = json.choices?.[0]?.message?.content?.trim() ?? "null";
  console.log(`extractName | message="${message.slice(0,60)}" | result="${result}"`);
  return result === "null" || !result ? null : result;
}

// ── Ensure lead exists — never duplicates ────────────────────────────────────
async function ensureLeadExists(businessId: number, email: string, name: string, existingId: number | null): Promise<number> {
  if (existingId) {
    await supabase.from("leads").update({ lead_name: name }).eq("id", existingId);
    return existingId;
  }
  const { data: existing } = await supabase.from("leads").select("id").eq("business_id", businessId).eq("lead_email", email).maybeSingle();
  if (existing) {
    await supabase.from("leads").update({ lead_name: name }).eq("id", existing.id);
    return existing.id;
  }
  const { data: created } = await supabase.from("leads").insert({
  business_id: businessId,
  lead_name: name,
  lead_email: email,
  lead_status: "In Conversation",
  date_added: new Date().toISOString(),
  last_message_at: new Date().toISOString(),
  source: "Email",
}).select("id").maybeSingle();
  return created!.id;
}

// ── Find available booking slots ──────────────────────────────────────────────
async function findAvailableSlots(
  availability: Record<string, any>,
  slotDurationMinutes: number,
  existingAppointments: Array<{ start_date_time: string; end_date_time: string }>
): Promise<Array<{ label: string; start: string; end: string }>> {
  const slots: Array<{ label: string; start: string; end: string }> = [];
  const now       = new Date();
  const dayNames   = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"];
  const dayShort   = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  const monthShort = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  for (let d = 0; d < 14 && slots.length < 3; d++) {
    const date    = new Date(now);
    date.setDate(now.getDate() + d);
    const dayConf = availability[dayNames[date.getDay()]];
    if (!dayConf?.enabled) continue;

    const [startH, startM] = (dayConf.start as string).split(":").map(Number);
    const [endH,   endM  ] = (dayConf.end   as string).split(":").map(Number);
    const blocks: Array<{ start: string; end: string }> = dayConf.blocks ?? [];

    let cursor = new Date(date); cursor.setHours(startH, startM, 0, 0);
    const dayEnd = new Date(date);
          dayEnd.setHours(endH, endM, 0, 0);

    while (cursor < dayEnd && slots.length < 3) {
      const slotStart = new Date(cursor);
      const slotEnd   = new Date(cursor);
      slotEnd.setMinutes(slotEnd.getMinutes() + slotDurationMinutes);
      if (slotEnd > dayEnd) break;
      if (slotStart <= new Date(now.getTime() + 2 * 60 * 60 * 1000)) {
        cursor.setMinutes(cursor.getMinutes() + slotDurationMinutes); continue;
      }
      const blockedByConfig = blocks.some((b) => {
        const [bSH, bSM] = (b.start as string).split(":").map(Number);
        const [bEH, bEM] = (b.end   as string).split(":").map(Number);
        const bStart = new Date(date); bStart.setHours(bSH + TZ_OFFSET_HOURS, bSM, 0, 0);
        const bEnd   = new Date(date); bEnd.setHours(bEH + TZ_OFFSET_HOURS, bEM, 0, 0);
        return slotStart < bE && slotEnd > bS;
      });
      const blockedByAppt = existingAppointments.some((a) =>
        slotStart < new Date(a.end_date_time) && slotEnd > new Date(a.start_date_time)
      );
      if (!blockedByConfig && !blockedByAppt) {
        const TZ_OFFSET_MS = -4 * 60 * 60 * 1000; // EDT = UTC-4
        const localStart   = new Date(slotStart.getTime() + TZ_OFFSET_MS);
        const h  = localStart.getUTCHours();
        const hr = h === 0 ? 12 : h > 12 ? h - 12 : h;
        slots.push({
          label: `${dayShort[localStart.getUTCDay()]} ${monthShort[localStart.getUTCMonth()]} ${localStart.getUTCDate()} at ${hr}:${localStart.getUTCMinutes().toString().padStart(2,"0")} ${h < 12 ? "AM" : "PM"}`,
          start: slotStart.toISOString(), end: slotEnd.toISOString(),
        });
      }
      cursor.setMinutes(cursor.getMinutes() + slotDurationMinutes);
    }
  }
  return slots;
}

// ── Build AI system prompt ────────────────────────────────────────────────────
async function buildSystemPrompt(biz: Record<string, any>, lead: Record<string, any> | null, contactName: string | null): Promise<string> {
  const { data: kbEntries } = await supabase.from("knowledge_base").select("title, short_answer, content, category")
    .eq("business_id", biz.id).eq("is_active", true).order("sort_order", { ascending: true });
  const kb = (kbEntries ?? []).map((e: any) => `[${e.category}] ${e.title}: ${e.short_answer || e.content || ""}`).join("\n");
  const address = [biz.address_line1, biz.address_line2, biz.city, biz.state, biz.zip_code].filter(Boolean).join(", ");
  const parts: string[] = [`You are ${biz.ai_persona || "a helpful assistant"} representing ${biz.business_name || "this business"}.`];
  if (biz.industry)     parts.push(`Industry: ${biz.industry}`);
  if (biz.primary_goal) parts.push(`Your primary goal: ${biz.primary_goal}`);
  const contactInfo = [
    biz.business_phone  ? `Phone: ${biz.business_phone}`      : "",
    biz.business_email  ? `Email: ${biz.business_email}`      : "",
    biz.company_website ? `Website: ${biz.company_website}`   : "",
    address             ? `Address: ${address}`               : "",
    biz.booking_link    ? `Booking link: ${biz.booking_link}` : "",
  ].filter(Boolean);
  if (contactInfo.length) parts.push(`BUSINESS CONTACT INFO:\n${contactInfo.join("\n")}`);
  if (biz.services_and_pricing) parts.push(`SERVICES & PRICING:\n${biz.services_and_pricing}`);
  if (kb)                       parts.push(`KNOWLEDGE BASE:\n${kb}`);
  if (biz.company_faqs)         parts.push(`FREQUENTLY ASKED QUESTIONS:\n${biz.company_faqs}`);
  if (contactName) parts.push(`CONTACT INFO:\nThe person's name is ${firstName(contactName)}. Use their first name naturally — not every sentence.`);
  if (lead?.lead_phone)   parts.push(`Their phone: ${lead.lead_phone}`);
  if (lead?.lead_address) parts.push(`Their address: ${lead.lead_address}`);
  if (biz.forbidden_words) parts.push(`NEVER mention or discuss: ${biz.forbidden_words}`);
  parts.push(`EMAIL RULES:
- Replies 2-4 sentences. Professional but warm.
- Plain text only. No markdown, bullets, or HTML.
- Never say you are an AI unless directly asked. If asked, be honest.
- No formal sign-offs needed.
- If you don't know something, say someone will follow up.
- If they want a human, say a team member will be in touch.`);
  return parts.join("\n\n");
}

// ── Generate AI reply ─────────────────────────────────────────────────────────
async function generateAiReply(systemPrompt: string, history: Array<{ role: string; content: string }>, message: string): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [{ role: "system", content: systemPrompt }, ...history.slice(-10), { role: "user", content: message }],
      max_tokens: 300, temperature: 0.65,
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`OpenAI error: ${JSON.stringify(json)}`);
  return json.choices?.[0]?.message?.content?.trim() ?? "";
}

// ── Detect booking intent ─────────────────────────────────────────────────────
async function detectIntent(message: string, history: Array<{ role: string; content: string }>): Promise<{ wantsBooking: boolean; isPickingSlot: boolean; slotChoice: number | null }> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: `Return ONLY valid JSON: {"wantsBooking":boolean,"isPickingSlot":boolean,"slotChoice":number|null}. isPickingSlot=true only if they reply 1, 2, or 3 to choose a time slot.` },
        ...history.slice(-4),
        { role: "user", content: message },
      ],
      max_tokens: 60, temperature: 0,
    }),
  });
  const json = await res.json();
  try { return JSON.parse(json.choices?.[0]?.message?.content?.trim() ?? "{}"); }
  catch { return { wantsBooking: false, isPickingSlot: false, slotChoice: null }; }
}

// ── Main handler ──────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  try {
    const fields = await parseMailgunPayload(req);

    const rawFrom      = fields["from"]         ?? fields["sender"]    ?? "";
    const rawTo        = fields["To"]            ?? fields["recipient"] ?? "";
    const subject      = fields["subject"]       ?? fields["Subject"]   ?? "(no subject)";
    const strippedText = fields["stripped-text"] ?? "";
    const bodyRaw      = fields["body-plain"]    ?? fields["body-html"] ?? "";
    const messageId    = fields["Message-Id"]    ?? fields["message-id"] ?? "";

    if (!rawFrom || (!strippedText && !bodyRaw)) {
      console.log("Missing from or body — skipping");
      return new Response("ok", { status: 200 });
    }

    const { name: senderName, email: senderEmail } = parseSender(rawFrom);

    // userMessage = only what the person typed this turn, stripped of quoted history
    const userMessage    = (strippedText || stripQuotedText(bodyRaw) || bodyRaw).trim().slice(0, 800);
    const bodyForStorage = bodyRaw || strippedText;

    console.log(`Inbound | from:${senderEmail} | userMessage:"${userMessage.slice(0, 120)}"`);

    if (senderEmail.includes("noreply") || senderEmail.includes("no-reply") || senderEmail.includes("mailer-daemon")) {
      return new Response("ok", { status: 200 });
    }

    // ── 1. Match business ────────────────────────────────────────────────────
    let biz: Record<string, any> | null = null;
    const { data: bizByEmail } = await supabase.from("businesses").select("*").eq("dedicated_email", rawTo.trim().toLowerCase()).maybeSingle();
    if (bizByEmail) {
      biz = bizByEmail;
    } else {
      const { data: anyBiz } = await supabase.from("businesses").select("*").limit(1).maybeSingle();
      if (!anyBiz) { console.error("No business found"); return new Response("ok", { status: 200 }); }
      biz = anyBiz;
    }
    const businessId = biz!.id as number;

    // ── 2. Deduplicate by Message-Id ─────────────────────────────────────────
    if (messageId) {
      const { data: dup } = await supabase.from("messages").select("id").eq("twilio_sid", messageId).maybeSingle();
      if (dup) { console.log("Duplicate — skipping"); return new Response("ok", { status: 200 }); }
    }

    // ── 3. Look up lead ──────────────────────────────────────────────────────
    const { data: lead } = await supabase.from("leads")
      .select("id, lead_name, lead_phone, lead_email, lead_address, lead_status")
      .eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();

    // ── 4. Find or create conversation ───────────────────────────────────────
    // Same-day rule: if a conversation exists for this email today, reuse it
    // regardless of Message-Id threading (handles email clients that break threads)
    const todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);

    let { data: conv } = await supabase.from("conversations").select("*")
      .eq("business_id", businessId)
      .eq("contact_email", senderEmail)
      .eq("channel", "email")
      .order("last_message_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    // Reuse if: no conv at all creates new, OR existing conv updated today = reuse it
    // If existing conv is from a previous day and name is verified, still reuse (same person)
    const isNewConvo = !conv;

    // Local mutable state — never re-read conv after this point
    let ci: Record<string, any> = conv?.collecting_info ?? {};

    // verifiedName: only trust the lead table or name_verified flag on conversation
    let verifiedName: string | null = lead?.lead_name ?? (conv?.name_verified ? conv?.contact_name : null) ?? null;

    if (!conv) {
      const { data: newConv, error: err } = await supabase.from("conversations").insert({
        business_id: businessId, contact_name: verifiedName ?? senderEmail,
        contact_email: senderEmail, contact_phone: lead?.lead_phone ?? null,
        lead_id: lead?.id ?? null, channel: "email", status: "open", ai_enabled: true,
        last_message: bodyForStorage.slice(0, 200), last_message_at: new Date().toISOString(),
        unread_count: 1, collecting_info: {}, pending_booking_slots: null,
        name_verified: !!verifiedName,
      }).select().maybeSingle();
      if (err) throw new Error(`Create conversation: ${err.message}`);
      conv = newConv;
      ci = {};
    } else {
      await supabase.from("conversations").update({
        last_message: bodyForStorage.slice(0, 200), last_message_at: new Date().toISOString(),
        unread_count: (conv.unread_count ?? 0) + 1, status: "open",
        lead_id: conv.lead_id ?? lead?.id ?? null,
      }).eq("id", conv.id);
    }

    const conversationId = conv!.id as number;

    // ── 5. Save inbound message ───────────────────────────────────────────────
    await supabase.from("messages").insert({
      conversation_id: conversationId, business_id: businessId,
      body: bodyForStorage, direction: "inbound", channel: "email",
      status: "delivered", sender_name: verifiedName ?? senderEmail, twilio_sid: messageId || null,
    });

    if (!(conv!.ai_enabled ?? true)) {
      console.log("AI paused"); return new Response("ok", { status: 200 });
    }

    // ── 6. Load conversation history ──────────────────────────────────────────
    const { data: recentMsgs } = await supabase.from("messages").select("body, direction")
      .eq("conversation_id", conversationId).order("created_at", { ascending: false }).limit(10);
    const history = (recentMsgs ?? []).reverse().map((m: any) => ({
      role: m.direction === "inbound" ? "user" : "assistant", content: m.body,
    }));

    const replyFrom = biz!.dedicated_email ?? `leads@${MAILGUN_DOMAIN}`;
    const replySubj = replySubject(subject);
    let aiReply = "";

    console.log(`ci.waiting_for="${ci.waiting_for}" | ci.name_collected=${ci.name_collected} | verifiedName="${verifiedName}" | name_verified=${conv!.name_verified}`);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE MACHINE
    // ═══════════════════════════════════════════════════════════════════════

    // ── WAITING FOR NAME ────────────────────────────────────────────────────
    if (ci.waiting_for === "name") {
      // If we suggested a name, check for ANY affirmative first — don't use AI for this
      // because AI struggles to connect "Yes!" or "Yep!" back to the suggested name
      const suggested = ci.suggested_name as string | null;
      const firstLine = userMessage.split(/\n/)[0].trim();
      const isAffirmative = /^(yes|yep|yeah|correct|sure|yup|right|ok|okay|affirmative|that'?s? ?(me|right|correct)?)[.!,?]?$/i.test(firstLine);

      let capturedName: string | null = null;
      if (suggested && isAffirmative) {
        // They confirmed the suggested name
        capturedName = suggested;
        console.log(`Name confirmed via affirmative: "${capturedName}"`);
      } else {
        // Use AI to extract name from their message (handles "It's Michael", "Michael App", etc.)
        capturedName = await extractNameFromMessage(userMessage, suggested);
      }

      if (capturedName) {
        const first  = firstName(capturedName);
        const leadId = await ensureLeadExists(businessId, senderEmail, capturedName, lead?.id ?? null);

        ci = { ...ci, waiting_for: null, name_collected: true, suggested_name: null };
        verifiedName = capturedName;

        await supabase.from("conversations").update({
          contact_name: capturedName, lead_id: leadId, collecting_info: ci, name_verified: true,
        }).eq("id", conversationId);

        const sp = await buildSystemPrompt(biz!, lead, capturedName);
        aiReply  = await generateAiReply(sp, history,
          `[SYSTEM: The person just told you their name is "${capturedName}". Greet them warmly as ${first} and ask how you can help. 1-2 sentences.]`);

      } else {
        // AI couldn't find a name — ask more clearly
        const hint = ci.suggested_name ? ` (or let me know if I have the wrong name)` : "";
        aiReply = `I just need your name to get started${hint} — could you reply with your first and last name?`;
      }

    // ── WAITING FOR LAST NAME ────────────────────────────────────────────────
    } else if (ci.waiting_for === "last_name") {
      const existingFirst = firstName(verifiedName ?? "");
      const firstLine     = userMessage.split(/\n/)[0].trim();

      // Try simple extraction first: 1-2 word response that looks like a name
      // Handles "App", "My last name is App", "It's App", "Johnson"
      let lastName: string | null = null;

      // Direct single/double word name response
      if (/^[a-zA-Z\-']{2,30}(\s[a-zA-Z\-']{2,30})?$/.test(firstLine)) {
        lastName = firstLine;
      } else {
        // Try to extract last name from a sentence like "My last name is App"
        const match = firstLine.match(/(?:(?:last\s+)?name\s+is|it'?s|i'?m|call me)\s+([a-zA-Z\-']+(?:\s[a-zA-Z\-']+)?)/i);
        if (match) lastName = match[1].trim();
      }

      // If simple extraction failed, try AI
      if (!lastName) {
        const extracted = await extractNameFromMessage(userMessage, null);
        if (extracted) lastName = extracted;
      }

      const fullName = lastName
        ? (lastName.toLowerCase().startsWith(existingFirst.toLowerCase())
            ? lastName  // they gave full name again
            : `${existingFirst} ${lastName}`)
        : null;

      console.log(`LAST NAME | firstLine="${firstLine}" | lastName="${lastName}" | fullName="${fullName}"`);

      if (fullName) {
        const leadId = await ensureLeadExists(businessId, senderEmail, fullName, lead?.id ?? null);
        ci = { ...ci, waiting_for: null, last_name_collected: true };
        verifiedName = fullName;
        await supabase.from("conversations").update({
          contact_name: fullName, lead_id: leadId, collecting_info: ci, name_verified: true,
        }).eq("id", conversationId);
        // Fall through to normal flow to continue booking
      } else {
        aiReply = `Could you share your last name as well, ${existingFirst}?`;
      }

    // ── WAITING FOR PHONE ────────────────────────────────────────────────────
    } else if (ci.waiting_for === "phone") {
      if (looksLikePhone(userMessage)) {
        const phone = "+" + userMessage.split(/\n/)[0].replace(/\D/g, "");
        ci = { ...ci, waiting_for: null, phone_collected: true };
        await supabase.from("conversations").update({ contact_phone: phone, collecting_info: ci }).eq("id", conversationId);
        if (lead) await supabase.from("leads").update({ lead_phone: phone }).eq("id", lead.id);
        else {
          const { data: fl } = await supabase.from("leads").select("id").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
          if (fl) await supabase.from("leads").update({ lead_phone: phone }).eq("id", fl.id);
        }
      }
      // Fall through to normal flow

    // ── WAITING FOR ADDRESS ──────────────────────────────────────────────────
    } else if (ci.waiting_for === "address") {
      if (looksLikeAddress(userMessage)) {
        const addr = userMessage.split(/\n/).slice(0, 3).join(", ");
        ci = { ...ci, waiting_for: null, address_collected: true };
        await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
        if (lead) await supabase.from("leads").update({ lead_address: addr }).eq("id", lead.id);
        else {
          const { data: fl } = await supabase.from("leads").select("id").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
          if (fl) await supabase.from("leads").update({ lead_address: addr }).eq("id", fl.id);
        }
      }
      // Fall through to normal flow
    }

    // ── NORMAL FLOW ──────────────────────────────────────────────────────────
    if (!aiReply) {
      const nameVerified = conv!.name_verified || !!verifiedName;

      if (!nameVerified) {
        // No verified name — ask or confirm from email header
        const bizName = biz!.business_name ?? "us";
        if (senderName) {
          aiReply = `Hi, thank you for reaching out to ${bizName}! Am I speaking with ${senderName}?`;
          ci = { ...ci, waiting_for: "name", suggested_name: senderName };
        } else {
          aiReply = `Hi, thank you for reaching out to ${bizName}! Could I get your full name first?`;
          ci = { ...ci, waiting_for: "name", suggested_name: null };
        }
        await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);

      } else {
        // Name is verified — normal conversation flow
        const currentName = verifiedName ?? conv!.contact_name;
        const first       = firstName(currentName);
        const pendingSlots = conv!.pending_booking_slots as Array<{ label: string; start: string; end: string }> | null;
        const intent       = await detectIntent(userMessage, history);

        // ── Picking a slot ───────────────────────────────────────────────
        if (pendingSlots?.length && intent.isPickingSlot && intent.slotChoice) {
          const chosen = pendingSlots[intent.slotChoice - 1];
          if (!chosen) {
            aiReply = `Sorry ${first}, please reply with 1, 2, or 3 to pick a time.`;
          } else {
            const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
            const hasPhone = fl?.lead_phone   || ci.phone_collected;
            const hasAddr  = fl?.lead_address || ci.address_collected;

            if (!hasPhone) {
              aiReply = `Great choice, ${first}! Before I confirm, could I get your phone number?`;
              ci = { ...ci, waiting_for: "phone", pending_slot_choice: intent.slotChoice };
              await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
            } else if (!hasAddr) {
              aiReply = `Almost there! Could I also get your full address, ${first}?`;
              ci = { ...ci, waiting_for: "address", pending_slot_choice: intent.slotChoice };
              await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
            } else {
              // Check if we need last name before booking
              if (!hasLastName(currentName) && !ci.last_name_collected) {
                aiReply = `Just one more thing — could I get your last name, ${first}?`;
                ci = { ...ci, waiting_for: "last_name", pending_slot_choice: intent.slotChoice };
                await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
              } else {
                const { data: newAppt } = await supabase.from("appointments").insert({
                  business_id: businessId, appointment_name: `Appointment – ${currentName}`,
                  appointment_type: "Consultation", status: "New",
                  start_date_time: chosen.start, end_date_time: chosen.end,
                  lead_name: currentName, lead_phone: fl?.lead_phone ?? "",
                  lead_email: senderEmail, notes: fl?.lead_address ? `Address: ${fl.lead_address}` : "",
                  confirmation_sent: false,
                }).select().maybeSingle();

                await supabase.from("conversations").update({ pending_booking_slots: null, collecting_info: { ...ci, waiting_for: null } }).eq("id", conversationId);
                if (fl) await supabase.from("leads").update({ lead_status: "In Conversation", converted_to_appointment: true, appointment_scheduled_at: chosen.start }).eq("id", fl.id);

                if (NOTIFY_OWNER_WEBHOOK) {
                  fetch(NOTIFY_OWNER_WEBHOOK, { method: "POST", headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ appointment_id: newAppt?.id, lead_name: currentName, lead_email: senderEmail, lead_phone: fl?.lead_phone ?? "", lead_address: fl?.lead_address ?? "", appointment_time: chosen.label, business_id: businessId, channel: "email" }),
                  }).catch((e) => console.error("Webhook:", e));
                }
                aiReply = `You're all set, ${first}! Booked for ${chosen.label}. We look forward to seeing you!`;
              }
            }
          }

        // ── Wants to book ────────────────────────────────────────────────
        } else if (intent.wantsBooking) {
          // Check last name first
          if (!hasLastName(currentName) && !ci.last_name_collected) {
            aiReply = `I'd love to help you schedule something, ${first}! Before I do, could I get your last name?`;
            ci = { ...ci, waiting_for: "last_name", booking_requested: true };
            await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
          } else {
            const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
            const hasPhone = fl?.lead_phone   || ci.phone_collected;
            const hasAddr  = fl?.lead_address || ci.address_collected;

            if (!hasPhone) {
              aiReply = `I'd be happy to help you schedule something, ${first}! Could I get your phone number first?`;
              ci = { ...ci, waiting_for: "phone", booking_requested: true };
              await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
            } else if (!hasAddr) {
              aiReply = `Thanks! And could I get your full address, ${first}?`;
              ci = { ...ci, waiting_for: "address", booking_requested: true };
              await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
            } else {
              const { data: existingAppts } = await supabase.from("appointments").select("start_date_time, end_date_time")
                .eq("business_id", businessId).gte("start_date_time", new Date().toISOString());
              const slots = await findAvailableSlots(biz!.availability_hours ?? {}, biz!.slot_duration_minutes ?? 60, existingAppts ?? []);
              if (!slots.length) {
                aiReply = `I'm sorry ${first}, no open slots in the next two weeks. Someone from our team will reach out to find a time.`;
              } else {
                await supabase.from("conversations").update({ pending_booking_slots: slots, collecting_info: { ...ci, waiting_for: null } }).eq("id", conversationId);
                aiReply = `Here are our next available times, ${first}:\n\n${slots.map((s, i) => `${i + 1}) ${s.label}`).join("\n")}\n\nReply with 1, 2, or 3 to confirm.`;
              }
            }
          }

        // ── Normal conversation ──────────────────────────────────────────
        } else {
          const sp = await buildSystemPrompt(biz!, lead, currentName);
          aiReply  = await generateAiReply(sp, history, userMessage);
        }
      }
    }

    if (!aiReply) {
      console.error("Empty AI reply"); return new Response("ok", { status: 200 });
    }

    console.log(`Sending reply: "${aiReply.slice(0, 100)}"`);

    await sendEmail({ to: senderEmail, from: `${biz!.business_name ?? "Support"} <${replyFrom}>`, replyTo: replyFrom, subject: replySubj, text: aiReply });
    await supabase.from("messages").insert({
      conversation_id: conversationId, business_id: businessId, body: aiReply,
      direction: "outbound", channel: "email", status: "delivered", sender_name: "AI Assistant", sent_via_twiml: true,
    });
    await supabase.from("conversations").update({ last_message: aiReply.slice(0, 200), last_message_at: new Date().toISOString() }).eq("id", conversationId);
    
    // Update lead last_message_at
    if (lead?.id) {
      await supabase.from("leads").update({
        last_message_at: new Date().toISOString(),
      }).eq("id", lead.id);
    }

    if (isNewConvo) {
      fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/run-automation`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}` },
        body: JSON.stringify({ trigger_type: "new_lead", business_id: businessId, payload: { lead_name: verifiedName ?? senderEmail, email: senderEmail, lead_id: lead?.id ?? null } }),
      }).catch((e) => console.error("Automation:", e));
    }

    return new Response("ok", { status: 200 });

  } catch (err) {
    console.error("receive-email error:", err);
    return new Response("ok", { status: 200 });
  }
});