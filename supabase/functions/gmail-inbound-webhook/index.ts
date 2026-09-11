import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const GMAIL_PUBSUB_SECRET = Deno.env.get("GMAIL_PUBSUB_SECRET") ?? "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ── Base64url helpers ────────────────────────────────────────────────────────
function decodeBase64Url(data: string): string {
  const normalized = data.replace(/-/g, "+").replace(/_/g, "/");
  return atob(normalized);
}
function decodeBase64UrlUtf8(data: string): string {
  const binary = decodeBase64Url(data);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder("utf-8").decode(bytes);
}
function encodeBase64Url(str: string): string {
  const bytes = new TextEncoder().encode(str);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ── Same helpers as receive-email ────────────────────────────────────────────
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

// ── EM-03: heuristic relevance check for automated/notification senders ──
// Same approach as receive-email's copy — cheap signal checks, no OpenAI
// call needed. Returns a 0–1 score where 1 = looks like a genuine human
// inquiry and 0 = looks fully automated. Takes the already-lowercased
// header map this file builds from msg.payload.headers (Gmail's format),
// unlike receive-email's version which parses Mailgun's message-headers
// JSON string — same scoring logic, different header source.
function computeRelevanceScore(headerMap: Record<string, string>, senderEmail: string): number {
  let score = 1.0;

  const local = senderEmail.split("@")[0] ?? "";
  const automatedLocalPattern = /(noreply|no-reply|donotreply|do-not-reply|notification|notifications|alert|alerts|mailer-daemon|automated|digest|newsletter)/i;
  if (automatedLocalPattern.test(local)) score -= 0.6;

  // List-Unsubscribe is near-universal on bulk/marketing/notification mail,
  // essentially never present on a genuine one-off human email.
  if (headerMap["list-unsubscribe"]) score -= 0.5;

  // Precedence: bulk/list/junk — standard automated-mail signal.
  if (/\b(bulk|list|junk)\b/i.test(headerMap["precedence"] ?? "")) score -= 0.3;

  // Auto-Submitted != "no" per RFC 3834 — explicit auto-generated marker.
  const autoSubmitted = (headerMap["auto-submitted"] ?? "").trim();
  if (autoSubmitted && !/^no$/i.test(autoSubmitted)) score -= 0.4;

  return Math.max(0, Math.min(1, score));
}

// EM-03: threshold now lives in platform_settings, editable by superusers
// without a redeploy. Falls back to 0.9 if the row is ever missing or the
// read fails, so a config problem never silently disables the whole gate.
async function getRelevanceThreshold(): Promise<number> {
  try {
    const { data } = await supabase
      .from("platform_settings")
      .select("value")
      .eq("key", "email_relevance_threshold")
      .maybeSingle();
    const v = data?.value;
    if (typeof v === "number" && v >= 0 && v <= 1) return v;
  } catch (e) {
    console.error("getRelevanceThreshold: read failed, falling back to 0.9:", e);
  }
  return 0.9;
}

// Gmail's plain-text quoting wraps "On <date> ... wrote:" across two lines
// (the email address often pushes it past one line), unlike Mailgun's
// single-line version in receive-email's stripQuotedText - checks both.
function stripQuotedText(body: string): string {
  const lines = body.split(/\r?\n/);
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith(">")) break;
    const nextLine = (lines[i + 1] ?? "").trim();
    if (/^on .{5,200}$/i.test(t) && (/wrote:\s*$/i.test(t) || /^wrote:\s*$/i.test(nextLine))) break;
    if (/^-{3,}\s*original message\s*-{3,}$/i.test(t)) break;
    if (/^from:\s+\S+@/i.test(t) && out.length > 0) break;
    out.push(lines[i]);
  }
  return out.join("\n").trim();
}

function extractBody(payload: any): string {
  function findPart(part: any): string | null {
    if (!part) return null;
    if (part.mimeType === "text/plain" && part.body?.data) return part.body.data;
    if (part.parts) {
      for (const p of part.parts) {
        const found = findPart(p);
        if (found) return found;
      }
    }
    return null;
  }
  const data = findPart(payload) ?? payload?.body?.data;
  if (!data) return "";
  try {
    return decodeBase64UrlUtf8(data);
  } catch {
    return "";
  }
}

// ── Token refresh (same pattern as quickbooks-token-refresh) ─────────────────
async function getFreshAccessToken(connection: {
  id: number;
  access_token_secret_id: string;
  refresh_token_secret_id: string;
  token_expires_at: string;
}): Promise<string | null> {
  const expiresAt = new Date(connection.token_expires_at).getTime();
  if (expiresAt > Date.now() + 2 * 60 * 1000) {
    const { data: accessToken } = await supabase.rpc("qb_vault_read_secret", {
      p_id: connection.access_token_secret_id,
    });
    return accessToken ?? null;
  }
  const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", {
    p_id: connection.refresh_token_secret_id,
  });
  if (!refreshToken) return null;
  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
    }),
  });
  if (!tokenResp.ok) {
    console.error("Gmail token refresh failed:", await tokenResp.text());
    return null;
  }
  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", { p_id: connection.access_token_secret_id, p_secret: tokens.access_token });
  await supabase
    .from("oauth_connections")
    .update({ token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(), updated_at: new Date().toISOString() })
    .eq("id", connection.id);
  return tokens.access_token;
}

// ── Send a reply through Gmail (replaces receive-email's Mailgun sendEmail) ──
async function sendGmailReply(opts: {
  accessToken: string;
  fromAddress: string;
  fromName: string;
  toAddress: string;
  subject: string;
  text: string;
  threadId?: string;
  inReplyToMessageId?: string;
}): Promise<{ id: string; threadId: string } | null> {
  const headerLines = [
    `To: ${opts.toAddress}`,
    `From: ${opts.fromName} <${opts.fromAddress}>`,
    `Subject: ${opts.subject}`,
    `Content-Type: text/plain; charset="UTF-8"`,
  ];
  if (opts.inReplyToMessageId) {
    headerLines.push(`In-Reply-To: ${opts.inReplyToMessageId}`);
    headerLines.push(`References: ${opts.inReplyToMessageId}`);
  }
  const raw = encodeBase64Url(`${headerLines.join("\r\n")}\r\n\r\n${opts.text}`);

  const res = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ raw, threadId: opts.threadId }),
  });
  if (!res.ok) {
    console.error("Gmail send failed:", await res.text());
    return null;
  }
  return await res.json();
}

// ── Same AI functions as receive-email (copied verbatim - generic, not Mailgun-specific) ──
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
      }, { role: "user", content: message }],
      max_tokens: 20,
      temperature: 0,
    }),
  });
  if (!res.ok) {
    console.error("extractNameFromMessage: OpenAI error:", await res.text());
    return null;
  }
  const json = await res.json();
  const result = json.choices?.[0]?.message?.content?.trim() ?? "null";
  return result === "null" || !result ? null : result;
}

async function ensureLeadExists(businessId: number, email: string, name: string, existingId: number | null): Promise<number> {
  if (existingId) {
    await supabase.from("leads").update({ lead_name: name }).eq("id", existingId);
    return existingId;
  }
  const { data: existing } = await supabase.from("leads").select("id").eq("business_id", businessId).eq("lead_email", email).is("deleted_at", null).maybeSingle();
  if (existing) {
    await supabase.from("leads").update({ lead_name: name }).eq("id", existing.id);
    return existing.id;
  }
  const { data: created } = await supabase.from("leads").insert({
    business_id: businessId, lead_name: name, lead_email: email, lead_status: "In Conversation",
    date_added: new Date().toISOString(), last_message_at: new Date().toISOString(), source: "Email",
  }).select("id").maybeSingle();
  return created!.id;
}

async function findAvailableSlots(
  availability: Record<string, any>,
  slotDurationMinutes: number,
  existingAppointments: Array<{ start_date_time: string; end_date_time: string }>,
  timezone: string,
): Promise<Array<{ label: string; start: string; end: string }>> {
  const slots: Array<{ label: string; start: string; end: string }> = [];
  const now = new Date();

  for (let d = 0; d < 14 && slots.length < 3; d++) {
    const checkDate = new Date(now.getTime() + d * 24 * 60 * 60 * 1000);
    const dateStr = checkDate.toISOString().slice(0, 10);
    const dayName = new Date(`${dateStr}T12:00:00.000Z`).toLocaleDateString("en-US", { weekday: "long", timeZone: timezone }).toLowerCase();
    const dayConf = availability[dayName];
    if (!dayConf || !dayConf.enabled) continue;

    const [startH, startM] = (dayConf.start as string).split(":").map(Number);
    const [endH, endM] = (dayConf.end as string).split(":").map(Number);
    const blocks: Array<{ start: string; end: string }> = dayConf.blocks ?? [];

    const testUtc = new Date(`${dateStr}T12:00:00.000Z`);
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: timezone, hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(testUtc);
    const localH = parseInt(parts.find((p) => p.type === "hour")!.value);
    const localM = parseInt(parts.find((p) => p.type === "minute")!.value);
    const offsetMinutes = 12 * 60 - (localH * 60 + localM);

    const dayStartUtc = new Date(`${dateStr}T00:00:00.000Z`);
    dayStartUtc.setTime(dayStartUtc.getTime() + (startH * 60 + startM + offsetMinutes) * 60 * 1000);
    const dayEndUtc = new Date(`${dateStr}T00:00:00.000Z`);
    dayEndUtc.setTime(dayEndUtc.getTime() + (endH * 60 + endM + offsetMinutes) * 60 * 1000);

    const cursor = new Date(dayStartUtc);
    while (cursor.getTime() + slotDurationMinutes * 60 * 1000 <= dayEndUtc.getTime() && slots.length < 3) {
      const slotStart = new Date(cursor);
      const slotEnd = new Date(cursor.getTime() + slotDurationMinutes * 60 * 1000);

      if (slotStart.getTime() <= now.getTime() + 2 * 60 * 60 * 1000) {
        cursor.setTime(cursor.getTime() + slotDurationMinutes * 60 * 1000);
        continue;
      }
      const blockedByDayConfig = blocks.some((b) => {
        const [bSH, bSM] = (b.start as string).split(":").map(Number);
        const [bEH, bEM] = (b.end as string).split(":").map(Number);
        const bStart = new Date(`${dateStr}T00:00:00.000Z`);
        bStart.setTime(bStart.getTime() + (bSH * 60 + bSM + offsetMinutes) * 60 * 1000);
        const bEnd = new Date(`${dateStr}T00:00:00.000Z`);
        bEnd.setTime(bEnd.getTime() + (bEH * 60 + bEM + offsetMinutes) * 60 * 1000);
        return slotStart < bEnd && slotEnd > bStart;
      });
      const blockedByAppt = existingAppointments.some((a) => {
        const aStart = new Date(a.start_date_time);
        const aEnd = new Date(a.end_date_time);
        return slotStart < aEnd && slotEnd > aStart;
      });
      if (!blockedByDayConfig && !blockedByAppt) {
        const label = new Intl.DateTimeFormat("en-US", {
          timeZone: timezone, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", hour12: true,
        }).format(slotStart).replace(",", " at");
        slots.push({ label, start: slotStart.toISOString(), end: slotEnd.toISOString() });
      }
      cursor.setTime(cursor.getTime() + slotDurationMinutes * 60 * 1000);
    }
  }
  return slots;
}

async function buildSystemPrompt(biz: Record<string, any>, lead: Record<string, any> | null, contactName: string | null): Promise<string> {
  const { data: kbEntries } = await supabase.from("knowledge_base").select("title, short_answer, content, category")
    .eq("business_id", biz.id).eq("is_active", true).order("sort_order", { ascending: true });
  const kb = (kbEntries ?? []).map((e: any) => `[${e.category}] ${e.title}: ${e.short_answer || e.content || ""}`).join("\n");
  const address = [biz.address_line1, biz.address_line2, biz.city, biz.state, biz.zip_code].filter(Boolean).join(", ");
  const parts: string[] = [`You are ${biz.ai_persona || "a helpful assistant"} representing ${biz.business_name || "this business"}.`];
  if (biz.industry) parts.push(`Industry: ${biz.industry}`);
  if (biz.primary_goal) parts.push(`Your primary goal: ${biz.primary_goal}`);
  const contactInfo = [
    biz.business_phone ? `Phone: ${biz.business_phone}` : "",
    biz.business_email ? `Email: ${biz.business_email}` : "",
    biz.company_website ? `Website: ${biz.company_website}` : "",
    address ? `Address: ${address}` : "",
    biz.booking_link ? `Booking link: ${biz.booking_link}` : "",
  ].filter(Boolean);
  if (contactInfo.length) parts.push(`BUSINESS CONTACT INFO:\n${contactInfo.join("\n")}`);
  if (biz.services_and_pricing) parts.push(`SERVICES & PRICING:\n${biz.services_and_pricing}`);
  if (kb) parts.push(`KNOWLEDGE BASE:\n${kb}`);
  if (biz.company_faqs) parts.push(`FREQUENTLY ASKED QUESTIONS:\n${biz.company_faqs}`);
  if (contactName) parts.push(`CONTACT INFO:\nThe person's name is ${firstName(contactName)}. Use their first name naturally — not every sentence.`);
  if (lead?.lead_phone) parts.push(`Their phone: ${lead.lead_phone}`);
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

async function detectIntent(message: string, history: Array<{ role: string; content: string }>): Promise<{ wantsBooking: boolean; isPickingSlot: boolean; slotChoice: number | null }> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: `Return ONLY valid JSON: {"wantsBooking":boolean,"isPickingSlot":boolean,"slotChoice":number|null}. wantsBooking=true if they are asking to schedule/book an appointment, OR if they are affirmatively responding to a previous assistant message (see conversation history) that offered or asked about scheduling one — e.g. "yes", "yes please", "sure", "that works", "yes I would". isPickingSlot=true only if they reply 1, 2, or 3 to choose a time slot.` },
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
    const url = new URL(req.url);
    if (!GMAIL_PUBSUB_SECRET || url.searchParams.get("secret") !== GMAIL_PUBSUB_SECRET) {
      console.error("gmail-inbound-webhook: invalid or missing secret");
      return new Response("Forbidden", { status: 403 });
    }

    const body = await req.json();
    const messageData = body?.message?.data;
    if (!messageData) return new Response("ok", { status: 200 });

    // Google Pub/Sub delivers each notification at-least-once, meaning the
    // same push routinely arrives twice within a few seconds. The existing
    // dedup-by-external_message_id check catches this after doing all the
    // work (OpenAI calls, Gmail API calls); this catches it before any of
    // that runs, keyed on Pub/Sub's own delivery-level message ID.
    const pubsubMessageId = body?.message?.messageId as string | undefined;
    if (pubsubMessageId) {
      const { error: dedupErr } = await supabase.from("pubsub_dedup").insert({ message_id: pubsubMessageId });
      if (dedupErr) {
        // Unique violation = we've already processed this exact delivery
        return new Response("ok", { status: 200 });
      }
    }

    const decoded = JSON.parse(decodeBase64UrlUtf8(messageData));
    const emailAddress = decoded.emailAddress as string | undefined;
    const newHistoryId = String(decoded.historyId ?? "");
    if (!emailAddress || !newHistoryId) return new Response("ok", { status: 200 });

    const { data: connection } = await supabase
      .from("oauth_connections")
      .select("id, business_id, access_token_secret_id, refresh_token_secret_id, token_expires_at")
      .eq("provider", "gmail").eq("connected_account_email", emailAddress).eq("connection_status", "active")
      .is("deleted_at", null).maybeSingle();
    if (!connection) return new Response("ok", { status: 200 });

    const { data: syncState } = await supabase
      .from("gmail_sync_state").select("id, history_id")
      .eq("oauth_connection_id", connection.id).is("deleted_at", null).maybeSingle();
    if (!syncState) return new Response("ok", { status: 200 });

    const accessToken = await getFreshAccessToken(connection);
    if (!accessToken) return new Response("ok", { status: 200 });

    const businessId = connection.business_id as number;
    const { data: biz } = await supabase.from("businesses").select("*").eq("id", businessId).maybeSingle();
    if (!biz) return new Response("ok", { status: 200 });

    const startHistoryId = syncState.history_id || newHistoryId;
    const historyResp = await fetch(
      `https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=${encodeURIComponent(startHistoryId)}&historyTypes=messageAdded&labelId=INBOX`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    if (!historyResp.ok) {
      if (historyResp.status === 404) {
        await supabase.from("gmail_sync_state").update({ history_id: newHistoryId, updated_at: new Date().toISOString() }).eq("id", syncState.id);
      } else {
        console.error("Gmail history.list failed:", await historyResp.text());
      }
      return new Response("ok", { status: 200 });
    }

    const historyJson = await historyResp.json();
    console.log(`gmail-inbound-webhook DEBUG: startHistoryId=${startHistoryId} newHistoryId=${newHistoryId} historyJson=${JSON.stringify(historyJson)}`);
    const messageIds = new Set<string>();
    for (const h of historyJson.history ?? []) {
      for (const added of h.messagesAdded ?? []) messageIds.add(added.message.id);
    }

    for (const gmailMessageId of messageIds) {
      const { data: existingMsg } = await supabase.from("messages").select("id")
        .eq("business_id", businessId).eq("external_message_id", gmailMessageId).maybeSingle();
      if (existingMsg) continue;

      const msgResp = await fetch(`https://gmail.googleapis.com/gmail/v1/users/me/messages/${gmailMessageId}?format=full`,
        { headers: { Authorization: `Bearer ${accessToken}` } });
      if (!msgResp.ok) { console.error(`Gmail messages.get failed for ${gmailMessageId}:`, await msgResp.text()); continue; }
      const msg = await msgResp.json();
      if ((msg.labelIds ?? []).includes("SENT")) continue;

      const headers: Record<string, string> = {};
      for (const h of msg.payload?.headers ?? []) headers[h.name.toLowerCase()] = h.value;

      const fromHeader = headers["from"] ?? "";
      const { name: senderName, email: senderEmail } = parseSender(fromHeader);
      if (!senderEmail || senderEmail === emailAddress) continue;
      if (senderEmail.includes("noreply") || senderEmail.includes("no-reply") || senderEmail.includes("mailer-daemon")) continue;

      // ── EM-03: relevance score for automated/notification senders ──────
      const relevanceScore = computeRelevanceScore(headers, senderEmail);
      const relevanceThreshold = await getRelevanceThreshold();
      const isLowRelevance = relevanceScore < relevanceThreshold;

      const subject = headers["subject"] ?? "(no subject)";
      const originalMessageIdHeader = headers["message-id"] ?? "";
      const rawBody = extractBody(msg.payload) || msg.snippet || "";
      const userMessage = (stripQuotedText(rawBody) || rawBody).trim().slice(0, 800);
      const bodyForStorage = userMessage;

      // ── Lead lookup ──
      // (also missing on receive-email's copy of this query - not touching that
      // working function without a separate ask, but flagging it as the same gap)
      const { data: lead } = await supabase.from("leads")
        .select("id, lead_name, lead_phone, lead_email, lead_address, lead_status")
        .eq("business_id", businessId).eq("lead_email", senderEmail).is("deleted_at", null).maybeSingle();

      // ── Conversation lookup (lead_id first - matches conversations_business_lead_channel_unique) ──
      let conv: any = null;
      if (lead?.id) {
        const { data: convByLead } = await supabase.from("conversations").select("*")
          .eq("business_id", businessId).eq("lead_id", lead.id).eq("channel", "email").is("deleted_at", null)
          .order("last_message_at", { ascending: false }).limit(1).maybeSingle();
        conv = convByLead;
      }
      if (!conv) {
        const { data: convByEmail } = await supabase.from("conversations").select("*")
          .eq("business_id", businessId).eq("contact_email", senderEmail).eq("channel", "email").is("deleted_at", null)
          .order("last_message_at", { ascending: false }).limit(1).maybeSingle();
        conv = convByEmail;
      }

      const isNewConvo = !conv;
      let ci: Record<string, any> = conv?.collecting_info ?? {};
      let verifiedName: string | null = lead?.lead_name ?? (conv?.name_verified ? conv?.contact_name : null) ?? null;

      if (!conv) {
        const { data: newConv, error: convErr } = await supabase.from("conversations").insert({
          business_id: businessId, contact_name: verifiedName ?? senderEmail, contact_email: senderEmail,
          contact_phone: lead?.lead_phone ?? null, lead_id: lead?.id ?? null, channel: "email", status: "open",
          ai_enabled: true, last_message: bodyForStorage.slice(0, 200), last_message_at: new Date().toISOString(),
          unread_count: 1, collecting_info: {}, pending_booking_slots: null, name_verified: !!verifiedName,
          relevance_score: relevanceScore, relevance_checked_at: new Date().toISOString(),
        }).select().maybeSingle();
        if (convErr) { console.error(`gmail-inbound-webhook: conversation insert failed:`, convErr); continue; }
        conv = newConv;
        ci = {};
      } else {
        await supabase.from("conversations").update({
          last_message: bodyForStorage.slice(0, 200), last_message_at: new Date().toISOString(),
          unread_count: (conv.unread_count ?? 0) + 1, status: "open", lead_id: conv.lead_id ?? lead?.id ?? null,
          relevance_score: relevanceScore, relevance_checked_at: new Date().toISOString(),
        }).eq("id", conv.id);
      }
      const conversationId = conv!.id as number;

      await supabase.from("messages").insert({
        conversation_id: conversationId, business_id: businessId, body: bodyForStorage, direction: "inbound",
        channel: "email", status: "delivered", sender_name: verifiedName ?? senderEmail, subject: subject,
        email_source: "gmail", external_message_id: gmailMessageId, external_thread_id: msg.threadId ?? null,
      });

      // ── EM-03: low-relevance short-circuit ──────────────────────────
      // Message is saved and the conversation is tagged with its
      // relevance_score regardless — but no AI reply, no name-collection
      // state machine, no lead auto-creation for senders that look
      // automated (bank/Google/YouTube alerts, spam, bulk mail). Uses
      // `continue` rather than `return` since this sits inside the
      // per-message loop — other messages in the same batch still need
      // to be processed.
      if (isLowRelevance) {
        console.log(`gmail-inbound-webhook: low relevance sender ${senderEmail} (score ${relevanceScore}) — saved message, no AI reply`);
        continue;
      }

      // ── EM-04: email_received automation trigger ──────────────────────
      // Same as receive-email's copy: fires on EVERY qualifying email,
      // independent of new_lead below which only fires on a brand-new
      // conversation. Placed before the AI-paused check so it still fires
      // even when a human has paused AI on this conversation.
      fetch(`${SUPABASE_URL}/functions/v1/run-automation`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}` },
        body: JSON.stringify({ trigger_type: "email_received", business_id: businessId, payload: { lead_name: verifiedName ?? senderEmail, email: senderEmail, lead_id: lead?.id ?? null } }),
      }).catch((e) => console.error("Automation (email_received):", e));

      if (!(conv!.ai_enabled ?? true)) continue; // AI paused on this conversation - leave for human

      const { data: recentMsgs } = await supabase.from("messages").select("body, direction")
        .eq("conversation_id", conversationId).order("created_at", { ascending: false }).limit(10);
      const history = (recentMsgs ?? []).reverse().map((m: any) => ({ role: m.direction === "inbound" ? "user" : "assistant", content: m.body }));

      let aiReply = "";
      const now = new Date();
      const windowResetAt = conv!.ai_reply_window_reset_at ? new Date(conv!.ai_reply_window_reset_at) : null;
      const windowExpired = !windowResetAt || (now.getTime() - windowResetAt.getTime()) > 24 * 60 * 60 * 1000;
      const currentReplyCount = windowExpired ? 0 : (conv!.ai_reply_count_24h ?? 0);
      const isAbuseBlocked = currentReplyCount >= 45;
      if (isAbuseBlocked) {
        aiReply = `I'll have someone from our team follow up with you directly to help from here.`;
        await supabase.from("conversations").update({ ai_enabled: false, flagged_for_abuse: true }).eq("id", conversationId);
      }

      let isBetaCapBlocked = false;
      if (!isAbuseBlocked && biz.is_beta && !biz.beta_card_added) {
        const capPeriod = new Date(); capPeriod.setUTCDate(1);
        const capPeriodStart = capPeriod.toISOString().slice(0, 10);
        const { data: usageRow } = await supabase.from("business_usage_live")
          .select("ai_messages_used, ai_messages_included").eq("business_id", businessId).eq("period_start", capPeriodStart).maybeSingle();
        if (usageRow && usageRow.ai_messages_used >= usageRow.ai_messages_included) isBetaCapBlocked = true;
      }
      const isBlocked = isAbuseBlocked || isBetaCapBlocked;
      if (isBetaCapBlocked) {
        aiReply = `Thanks for your patience — our AI assistant has reached its monthly message limit for now. A team member will follow up with you directly.`;
        await supabase.from("conversations").update({ ai_enabled: false, flagged_for_beta_cap: true }).eq("id", conversationId);
        fetch(`${SUPABASE_URL}/functions/v1/notify-beta-cap-reached`, {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ business_id: businessId }),
        }).catch((e) => console.error("notify-beta-cap-reached error:", e));
      }

      // ── STATE MACHINE (same shape as receive-email) ──
      if (!isBlocked && ci.waiting_for === "name") {
        const suggested = ci.suggested_name as string | null;
        const firstLine = userMessage.split(/\n/)[0].trim();
        const isAffirmative = /^(yes|yep|yeah|correct|sure|yup|right|ok|okay|affirmative|that'?s? ?(me|right|correct)?)\b/i.test(firstLine);
        let capturedName: string | null = null;
        if (suggested && isAffirmative) capturedName = suggested;
        else capturedName = await extractNameFromMessage(userMessage, suggested);

        if (capturedName) {
          const first = firstName(capturedName);
          const leadId = await ensureLeadExists(businessId, senderEmail, capturedName, lead?.id ?? null);
          ci = { ...ci, waiting_for: null, name_collected: true, suggested_name: null };
          verifiedName = capturedName;
          const { error: nameConfirmErr } = await supabase.from("conversations").update({ contact_name: capturedName, lead_id: leadId, collecting_info: ci, name_verified: true }).eq("id", conversationId);
          if (nameConfirmErr) console.error(`gmail-inbound-webhook: name-confirm update failed for conversation ${conversationId}:`, nameConfirmErr);
          const sp = await buildSystemPrompt(biz, lead, capturedName);
          aiReply = await generateAiReply(sp, history, `[SYSTEM: The person just told you their name is "${capturedName}". Greet them warmly as ${first} and ask how you can help. 1-2 sentences.]`);
        } else {
          const hint = ci.suggested_name ? ` (or let me know if I have the wrong name)` : "";
          aiReply = `I just need your name to get started${hint} — could you reply with your first and last name?`;
        }
      } else if (!isBlocked && ci.waiting_for === "last_name") {
        const existingFirst = firstName(verifiedName ?? "");
        const firstLine = userMessage.split(/\n/)[0].trim();
        let lastName: string | null = null;
        if (/^[a-zA-Z\-']{2,30}(\s[a-zA-Z\-']{2,30})?$/.test(firstLine)) lastName = firstLine;
        else {
          const match = firstLine.match(/(?:(?:last\s+)?name\s+is|it'?s|i'?m|call me)\s+([a-zA-Z\-']+(?:\s[a-zA-Z\-']+)?)/i);
          if (match) lastName = match[1].trim();
        }
        if (!lastName) { const extracted = await extractNameFromMessage(userMessage, null); if (extracted) lastName = extracted; }
        const fullName = lastName ? (lastName.toLowerCase().startsWith(existingFirst.toLowerCase()) ? lastName : `${existingFirst} ${lastName}`) : null;

        if (fullName) {
          const leadId = await ensureLeadExists(businessId, senderEmail, fullName, lead?.id ?? null);
          ci = { ...ci, waiting_for: null, last_name_collected: true };
          verifiedName = fullName;
          await supabase.from("conversations").update({ contact_name: fullName, lead_id: leadId, collecting_info: ci, name_verified: true }).eq("id", conversationId);
        } else {
          aiReply = `Could you share your last name as well, ${existingFirst}?`;
        }
      } else if (!isBlocked && ci.waiting_for === "phone") {
        if (looksLikePhone(userMessage)) {
          const phone = "+" + userMessage.split(/\n/)[0].replace(/\D/g, "");
          ci = { ...ci, waiting_for: null, phone_collected: true };
          await supabase.from("conversations").update({ contact_phone: phone, collecting_info: ci }).eq("id", conversationId);
          if (lead) await supabase.from("leads").update({ lead_phone: phone }).eq("id", lead.id);
        }
      } else if (!isBlocked && ci.waiting_for === "address") {
        if (looksLikeAddress(userMessage)) {
          const addr = userMessage.split(/\n/).slice(0, 3).join(", ");
          ci = { ...ci, waiting_for: null, address_collected: true };
          await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
          if (lead) await supabase.from("leads").update({ lead_address: addr }).eq("id", lead.id);
        }
      }

      if (!aiReply) {
        const nameVerified = conv!.name_verified || !!verifiedName;
        if (!nameVerified) {
          const bizName = biz.business_name ?? "us";
          if (senderName) { aiReply = `Hi, thank you for reaching out to ${bizName}! Am I speaking with ${senderName}?`; ci = { ...ci, waiting_for: "name", suggested_name: senderName }; }
          else { aiReply = `Hi, thank you for reaching out to ${bizName}! Could I get your full name first?`; ci = { ...ci, waiting_for: "name", suggested_name: null }; }
          await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
        } else {
          const currentName = verifiedName ?? conv!.contact_name;
          const first = firstName(currentName);
          const pendingSlots = conv!.pending_booking_slots as Array<{ label: string; start: string; end: string }> | null;
          const intent = await detectIntent(userMessage, history);

          if (pendingSlots?.length && intent.isPickingSlot && intent.slotChoice) {
            const chosen = pendingSlots[intent.slotChoice - 1];
            if (!chosen) { aiReply = `Sorry ${first}, please reply with 1, 2, or 3 to pick a time.`; }
            else {
              const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
              const hasPhone = fl?.lead_phone || ci.phone_collected;
              const hasAddr = fl?.lead_address || ci.address_collected;
              if (!hasPhone) { aiReply = `Great choice, ${first}! Before I confirm, could I get your phone number?`; ci = { ...ci, waiting_for: "phone", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else if (!hasAddr) { aiReply = `Almost there! Could I also get your full address, ${first}?`; ci = { ...ci, waiting_for: "address", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else if (!hasLastName(currentName) && !ci.last_name_collected) { aiReply = `Just one more thing — could I get your last name, ${first}?`; ci = { ...ci, waiting_for: "last_name", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else {
                const { data: newAppt } = await supabase.from("appointments").insert({
                  business_id: businessId, calendar_id: biz.default_calendar_id ?? null, appointment_name: `Appointment – ${currentName}`,
                  appointment_type: "Consultation", status: "New", start_date_time: chosen.start, end_date_time: chosen.end,
                  lead_id: fl?.id ?? lead?.id ?? null, lead_name: currentName, lead_phone: fl?.lead_phone ?? "", lead_email: senderEmail,
                  notes: fl?.lead_address ? `Address: ${fl.lead_address}` : "", confirmation_sent: false,
                }).select().maybeSingle();
                await supabase.from("conversations").update({ pending_booking_slots: null, collecting_info: { ...ci, waiting_for: null } }).eq("id", conversationId);
                if (fl) await supabase.from("leads").update({ lead_status: "In Conversation", converted_to_appointment: true, appointment_scheduled_at: chosen.start }).eq("id", fl.id);
                aiReply = `You're all set, ${first}! Booked for ${chosen.label}. We look forward to seeing you!`;
              }
            }
          } else if (intent.wantsBooking) {
            if (!hasLastName(currentName) && !ci.last_name_collected) { aiReply = `I'd love to help you schedule something, ${first}! Before I do, could I get your last name?`; ci = { ...ci, waiting_for: "last_name", booking_requested: true }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
            else {
              const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", senderEmail).maybeSingle();
              const hasPhone = fl?.lead_phone || ci.phone_collected;
              const hasAddr = fl?.lead_address || ci.address_collected;
              if (!hasPhone) { aiReply = `I'd be happy to help you schedule something, ${first}! Could I get your phone number first?`; ci = { ...ci, waiting_for: "phone", booking_requested: true }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else if (!hasAddr) { aiReply = `Thanks! And could I get your full address, ${first}?`; ci = { ...ci, waiting_for: "address", booking_requested: true }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else {
                const { data: existingAppts } = await supabase.from("appointments").select("start_date_time, end_date_time").eq("business_id", businessId).gte("start_date_time", new Date().toISOString());
                const slots = await findAvailableSlots(biz.availability_hours ?? {}, biz.slot_duration_minutes ?? 60, existingAppts ?? [], biz.timezone || "America/New_York");
                if (!slots.length) { aiReply = `I'm sorry ${first}, no open slots in the next two weeks. Someone from our team will reach out to find a time.`; }
                else { await supabase.from("conversations").update({ pending_booking_slots: slots, collecting_info: { ...ci, waiting_for: null } }).eq("id", conversationId); aiReply = `Here are our next available times, ${first}:\n\n${slots.map((s, i) => `${i + 1}) ${s.label}`).join("\n")}\n\nReply with 1, 2, or 3 to confirm.`; }
              }
            }
          } else {
            const sp = await buildSystemPrompt(biz, lead, currentName);
            aiReply = await generateAiReply(sp, history, userMessage);
          }
        }
      }

      if (!aiReply) continue;

      await supabase.rpc("increment_ai_usage", { p_business_id: businessId });
      if (!isAbuseBlocked) {
        await supabase.from("conversations").update({
          ai_reply_count_24h: currentReplyCount + 1,
          ai_reply_window_reset_at: windowExpired ? now.toISOString() : (conv!.ai_reply_window_reset_at ?? now.toISOString()),
        }).eq("id", conversationId);
      }

      const sent = await sendGmailReply({
        accessToken, fromAddress: emailAddress, fromName: biz.business_name ?? "Support",
        toAddress: senderEmail, subject: replySubject(subject), text: aiReply,
        threadId: msg.threadId, inReplyToMessageId: originalMessageIdHeader,
      });

      await supabase.from("messages").insert({
        conversation_id: conversationId, business_id: businessId, body: aiReply, direction: "outbound",
        channel: "email", status: "delivered", sender_name: "AI Assistant", sent_via_twiml: true,
        email_source: "gmail", external_message_id: sent?.id ?? null, external_thread_id: sent?.threadId ?? msg.threadId ?? null,
      });
      await supabase.from("conversations").update({ last_message: aiReply.slice(0, 200), last_message_at: new Date().toISOString() }).eq("id", conversationId);
      if (lead?.id) await supabase.from("leads").update({ last_message_at: new Date().toISOString() }).eq("id", lead.id);

      if (isNewConvo) {
        fetch(`${SUPABASE_URL}/functions/v1/run-automation`, {
          method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}` },
          body: JSON.stringify({ trigger_type: "new_lead", business_id: businessId, payload: { lead_name: verifiedName ?? senderEmail, email: senderEmail, lead_id: lead?.id ?? null } }),
        }).catch((e) => console.error("Automation:", e));
      }
    }

    await supabase.from("gmail_sync_state").update({ history_id: newHistoryId, last_polled_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", syncState.id);
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error("gmail-inbound-webhook error:", e);
    return new Response("ok", { status: 200 });
  }
});