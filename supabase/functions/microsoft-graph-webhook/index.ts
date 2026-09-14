import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;
const MICROSOFT_CLIENT_ID = Deno.env.get("MICROSOFT_CLIENT_ID")!;
const MICROSOFT_CLIENT_SECRET = Deno.env.get("MICROSOFT_CLIENT_SECRET")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Must match microsoft-oauth-callback's scopes exactly — a refresh grant
// that requests different scopes than were originally consented to can be
// rejected by Microsoft depending on tenant policy.
const MICROSOFT_SCOPES = [
  "offline_access",
  "https://graph.microsoft.com/Mail.ReadWrite",
  "https://graph.microsoft.com/Mail.Send",
  "https://graph.microsoft.com/User.Read",
].join(" ");

// ── Same helpers as receive-email / gmail-inbound-webhook ──────────────────
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

// ── EM-03: heuristic relevance check — same scoring as receive-email/Gmail,
// reading from Graph's internetMessageHeaders array instead of Mailgun's
// message-headers JSON string or Gmail's payload.headers array.
function computeRelevanceScore(headerMap: Record<string, string>, senderEmail: string): number {
  let score = 1.0;
  const local = senderEmail.split("@")[0] ?? "";
  const automatedLocalPattern = /(noreply|no-reply|donotreply|do-not-reply|notification|notifications|alert|alerts|mailer-daemon|automated|digest|newsletter)/i;
  if (automatedLocalPattern.test(local)) score -= 0.6;
  if (headerMap["list-unsubscribe"]) score -= 0.5;
  if (/\b(bulk|list|junk)\b/i.test(headerMap["precedence"] ?? "")) score -= 0.3;
  const autoSubmitted = (headerMap["auto-submitted"] ?? "").trim();
  if (autoSubmitted && !/^no$/i.test(autoSubmitted)) score -= 0.4;
  return Math.max(0, Math.min(1, score));
}

// EM-03: threshold lives in platform_settings, editable by superusers
// without a redeploy. Falls back to 0.9 if the row is ever missing.
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

// ── EM-05: business-scoped sender allow/block/keyword rule check ──────────
// Same as receive-email/Gmail's copy. Allow wins first and short-circuits
// everything else — the business's own exceptions list.
async function checkSenderRules(businessId: number, senderEmail: string, subject: string, bodyText: string): Promise<{ verdict: "allow" | "block" | null; matchedValue: string | null; matchedScope: string | null }> {
  const domain = senderEmail.split("@")[1]?.toLowerCase() ?? "";
  const subjectLower = (subject ?? "").toLowerCase();
  const bodyLower = (bodyText ?? "").toLowerCase();
  const { data: rules } = await supabase
    .from("email_sender_rules")
    .select("rule_type, match_value, match_scope")
    .eq("business_id", businessId)
    .is("deleted_at", null);

  if (!rules || !rules.length) return { verdict: null, matchedValue: null, matchedScope: null };

  const matches = (r: { match_scope: string; match_value: string }) => {
    const v = r.match_value.toLowerCase();
    if (r.match_scope === "email") return v === senderEmail;
    if (r.match_scope === "domain") return v === domain;
    if (r.match_scope === "keyword") return subjectLower.includes(v) || bodyLower.includes(v);
    return false;
  };

  const allowRule = rules.find((r) => r.rule_type === "allow" && matches(r));
  if (allowRule) return { verdict: "allow", matchedValue: allowRule.match_value, matchedScope: allowRule.match_scope };

  const blockRule =
    rules.find((r) => r.rule_type === "block" && r.match_scope !== "keyword" && matches(r)) ??
    rules.find((r) => r.rule_type === "block" && r.match_scope === "keyword" && matches(r));
  if (blockRule) return { verdict: "block", matchedValue: blockRule.match_value, matchedScope: blockRule.match_scope };

  return { verdict: null, matchedValue: null, matchedScope: null };
}

// ── EM-05: header-based trust check — same signals, reading from Graph's
// internetMessageHeaders map.
function checkTrustHeaders(headerMap: Record<string, string>): { trusted: boolean; reason: string | null } {
  const authResults = (headerMap["authentication-results"] ?? "").toLowerCase();
  if (/\bspf=fail\b/.test(authResults))   return { trusted: false, reason: "spf_fail" };
  if (/\bdkim=fail\b/.test(authResults))  return { trusted: false, reason: "dkim_fail" };
  if (/\bdmarc=fail\b/.test(authResults)) return { trusted: false, reason: "dmarc_fail" };
  const autoSubmitted = (headerMap["auto-submitted"] ?? "").trim();
  if (autoSubmitted && !/^no$/i.test(autoSubmitted)) return { trusted: false, reason: "auto_submitted" };
  if (headerMap["list-id"]) return { trusted: false, reason: "list_id" };
  if (/\bbulk\b/i.test(headerMap["precedence"] ?? "")) return { trusted: false, reason: "precedence_bulk" };
  return { trusted: true, reason: null };
}

// ── Graph returns body.content as HTML by default — strip tags to plain
// text before this reaches the AI prompt or relevance scoring.
function htmlToText(html: string): string {
  return html
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// Fallback only — Graph's uniqueBody normally already excludes quoted
// history, unlike Mailgun/Gmail which need this stripped manually. Kept
// as a safety net for the rare message where uniqueBody equals the full body.
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

// ── Token refresh. Unlike Gmail (which keeps the same refresh token
// indefinitely), Microsoft can rotate the refresh token on any refresh
// call — if a new one comes back, it MUST be re-vaulted or the next
// refresh will fail against a stale token.
async function getFreshAccessToken(connection: {
  id: number;
  access_token_secret_id: string;
  refresh_token_secret_id: string;
  token_expires_at: string;
}): Promise<string | null> {
  const expiresAt = new Date(connection.token_expires_at).getTime();
  if (expiresAt > Date.now() + 2 * 60 * 1000) {
    const { data: accessToken } = await supabase.rpc("qb_vault_read_secret", { p_id: connection.access_token_secret_id });
    return accessToken ?? null;
  }
  const { data: refreshToken } = await supabase.rpc("qb_vault_read_secret", { p_id: connection.refresh_token_secret_id });
  if (!refreshToken) return null;

  const tokenResp = await fetch("https://login.microsoftonline.com/common/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: MICROSOFT_CLIENT_ID,
      client_secret: MICROSOFT_CLIENT_SECRET,
      scope: MICROSOFT_SCOPES,
    }),
  });
  if (!tokenResp.ok) {
    console.error("microsoft-graph-webhook: token refresh failed:", await tokenResp.text());
    return null;
  }
  const tokens = await tokenResp.json();
  await supabase.rpc("qb_vault_update_secret", { p_id: connection.access_token_secret_id, p_secret: tokens.access_token });
  if (tokens.refresh_token) {
    await supabase.rpc("qb_vault_update_secret", { p_id: connection.refresh_token_secret_id, p_secret: tokens.refresh_token });
  }
  await supabase
    .from("oauth_connections")
    .update({ token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(), updated_at: new Date().toISOString() })
    .eq("id", connection.id);
  return tokens.access_token;
}

// ── Send a reply via Graph. createReply + send (two calls) instead of the
// simpler one-shot /reply endpoint, because /reply returns no body — we'd
// have no external_message_id to store for this outbound message, breaking
// the same kind of audit trail this session already fixed for the
// Gmail-fail-to-Mailgun case in outbound-email-send.
async function sendGraphReply(opts: {
  accessToken: string;
  messageId: string;
  commentText: string;
}): Promise<{ id: string } | null> {
  const createResp = await fetch(`https://graph.microsoft.com/v1.0/me/messages/${opts.messageId}/createReply`, {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ comment: opts.commentText }),
  });
  if (!createResp.ok) {
    console.error("microsoft-graph-webhook: createReply failed:", await createResp.text());
    return null;
  }
  const draft = await createResp.json();
  const sendResp = await fetch(`https://graph.microsoft.com/v1.0/me/messages/${draft.id}/send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${opts.accessToken}` },
  });
  if (!sendResp.ok) {
    console.error("microsoft-graph-webhook: reply send failed:", await sendResp.text());
    return null;
  }
  return { id: draft.id as string };
}

// ── Same AI functions as receive-email / gmail-inbound-webhook (generic,
// not provider-specific — copied verbatim per this codebase's existing
// per-function self-containment pattern) ──
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

// ── Main handler ─────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);

    // Microsoft Graph's subscription validation handshake — sent whenever a
    // subscription is created or renewed, as a request carrying
    // ?validationToken=... . Must be echoed back as plain text within 10
    // seconds or the subscription is rejected. This must stay ahead of
    // every other check in this handler.
    const validationToken = url.searchParams.get("validationToken");
    if (validationToken) {
      return new Response(validationToken, { status: 200, headers: { "Content-Type": "text/plain" } });
    }

    if (req.method !== "POST") {
      return new Response("ok", { status: 200 });
    }

    const body = await req.json().catch(() => null);
    const notifications = body?.value as Array<any> | undefined;
    if (!notifications || !notifications.length) {
      return new Response("ok", { status: 202 });
    }

    for (const item of notifications) {
      const subscriptionId = item.subscriptionId as string | undefined;
      const notifiedClientState = item.clientState as string | undefined;
      const graphMessageId = item.resourceData?.id as string | undefined;
      if (!subscriptionId || !graphMessageId) continue;

      // ── client_state verification ──────────────────────────────────────
      // Same principle as receive-email's Mailgun HMAC check — without
      // this, anyone who discovers this URL could POST a forged
      // notification shaped like a real inbound email and walk the AI
      // through a fake conversation at real OpenAI cost. NEVER remove.
      const { data: sub } = await supabase
        .from("email_sync_subscriptions")
        .select("id, oauth_connection_id, client_state")
        .eq("graph_subscription_id", subscriptionId)
        .is("deleted_at", null)
        .maybeSingle();

      if (!sub || !sub.client_state || sub.client_state !== notifiedClientState) {
        console.error(`microsoft-graph-webhook: client_state mismatch or unknown subscription ${subscriptionId} — rejecting`);
        continue;
      }

      const { data: connection } = await supabase
        .from("oauth_connections")
        .select("id, business_id, connected_account_email, access_token_secret_id, refresh_token_secret_id, token_expires_at, connection_status")
        .eq("id", sub.oauth_connection_id)
        .is("deleted_at", null)
        .maybeSingle();
      if (!connection || connection.connection_status !== "active") continue;

      // Token refresh failures here are left alone (not escalated to
      // token_error/revoked) — that escalation-on-repeated-failure logic
      // belongs to renew-graph-subscriptions, which tracks failure counts
      // across time. A single miss here just skips this notification.
      const accessToken = await getFreshAccessToken(connection as any);
      if (!accessToken) {
        console.error(`microsoft-graph-webhook: no usable access token for connection ${connection.id}`);
        continue;
      }

      const businessId = connection.business_id as number;

      // ── Dedup by Graph message ID (at-least-once delivery) ─────────────
      const { data: existingMsg } = await supabase
        .from("messages")
        .select("id")
        .eq("business_id", businessId)
        .eq("external_message_id", graphMessageId)
        .maybeSingle();
      if (existingMsg) continue;

      // ── Fetch the actual message ────────────────────────────────────────
      const msgResp = await fetch(
        `https://graph.microsoft.com/v1.0/me/messages/${graphMessageId}` +
          `?$select=subject,from,bodyPreview,body,uniqueBody,conversationId,internetMessageId,internetMessageHeaders,receivedDateTime`,
        { headers: { Authorization: `Bearer ${accessToken}` } },
      );
      if (!msgResp.ok) {
        console.error(`microsoft-graph-webhook: messages.get failed for ${graphMessageId}:`, await msgResp.text());
        continue;
      }
      const msg = await msgResp.json();

      const fromAddress = ((msg.from?.emailAddress?.address as string | undefined) ?? "").trim().toLowerCase();
      const fromName = msg.from?.emailAddress?.name as string | undefined;
      if (!fromAddress || fromAddress === (connection.connected_account_email ?? "").toLowerCase()) continue;
      if (fromAddress.includes("noreply") || fromAddress.includes("no-reply") || fromAddress.includes("mailer-daemon")) continue;

      const headerMap: Record<string, string> = {};
      for (const h of msg.internetMessageHeaders ?? []) {
        if (h?.name) headerMap[String(h.name).toLowerCase()] = String(h.value ?? "");
      }

      const rawBody = msg.uniqueBody?.content ?? msg.body?.content ?? msg.bodyPreview ?? "";
      const isHtml = (msg.uniqueBody?.contentType ?? msg.body?.contentType) === "html";
      const plainBody = isHtml ? htmlToText(rawBody) : rawBody;
      const userMessage = (stripQuotedText(plainBody) || plainBody).trim().slice(0, 800);
      const subject = msg.subject ?? "(no subject)";

      const { data: biz } = await supabase.from("businesses").select("*").eq("id", businessId).maybeSingle();
      if (!biz) continue;

      // ── EM-03 relevance ──
      let relevanceScore = computeRelevanceScore(headerMap, fromAddress);
      const relevanceThreshold = await getRelevanceThreshold();
      let isLowRelevance = relevanceScore < relevanceThreshold;

      // ── EM-05 trust filtering (Growth+ only) ──
      let trustStatus: string | null = null;
      let trustReason: string | null = null;

      const { data: trustFilteringEnabled } = await supabase.rpc("check_plan_feature", {
        p_business_id: businessId,
        p_feature: "email_trust_filtering",
      });
      const emailFilteringEnabledForBiz = biz.email_trust_filtering_enabled ?? true;

      if (trustFilteringEnabled && emailFilteringEnabledForBiz) {
        const senderRuleResult = await checkSenderRules(businessId, fromAddress, subject, userMessage);

        if (senderRuleResult.verdict === "block") {
          const { data: existingFiltered } = await supabase
            .from("filtered_emails")
            .select("id")
            .eq("business_id", businessId)
            .eq("external_message_id", graphMessageId)
            .maybeSingle();
          if (existingFiltered) continue;

          await supabase.from("filtered_emails").insert({
            business_id: businessId,
            raw_to_address: connection.connected_account_email,
            raw_from_address: fromAddress,
            subject,
            rule_matched: `block:${senderRuleResult.matchedScope}:${senderRuleResult.matchedValue}`,
            external_message_id: graphMessageId,
          });
          continue;
        }

        if (senderRuleResult.verdict === "allow") {
          trustStatus = "trusted";
          trustReason = `allowlisted:${senderRuleResult.matchedScope}:${senderRuleResult.matchedValue}`;
        } else {
          const trustHeaderResult = checkTrustHeaders(headerMap);
          if (!trustHeaderResult.trusted) {
            const isBulkReason = trustHeaderResult.reason === "auto_submitted" || trustHeaderResult.reason === "list_id" || trustHeaderResult.reason === "precedence_bulk";
            trustStatus = isBulkReason ? "filtered_bulk" : "filtered_auth_fail";
            trustReason = trustHeaderResult.reason;
            relevanceScore = 0;
            isLowRelevance = true;
          } else {
            trustStatus = "trusted";
          }
        }
      }

      // ── Lead lookup ──
      const { data: lead } = await supabase.from("leads")
        .select("id, lead_name, lead_phone, lead_email, lead_address, lead_status")
        .eq("business_id", businessId).eq("lead_email", fromAddress).is("deleted_at", null).maybeSingle();

      // ── Find or create conversation — MUST use the shared RPC, never a
      // parallel lookup. This is what unifies a lead across SMS/email/
      // Outlook into one conversation thread. Do NOT add any "sender must
      // already be a known contact" filter here or anywhere in this file —
      // that's the explicit GHL weakness this product is built to avoid.
      const initialVerifiedForCreate = lead?.lead_name ?? null;
      const { data: convJson, error: convErr } = await supabase.rpc("find_or_create_conversation", {
        p_business_id: businessId,
        p_channel: "email",
        p_contact_email: fromAddress,
        p_contact_phone: lead?.lead_phone ?? null,
        p_contact_name: initialVerifiedForCreate ?? fromAddress,
        p_lead_id: lead?.id ?? null,
        p_last_message: userMessage.slice(0, 200),
        p_relevance_score: relevanceScore,
        p_name_verified: !!initialVerifiedForCreate,
      });
      if (convErr || !convJson) {
        console.error(`microsoft-graph-webhook: find_or_create_conversation failed:`, convErr);
        continue;
      }

      const isNewConvo = !!convJson.was_created;
      const conv: Record<string, any> = convJson;
      let ci: Record<string, any> = conv.collecting_info ?? {};
      let verifiedName: string | null = lead?.lead_name ?? (conv.name_verified ? conv.contact_name : null) ?? null;

      if (!isNewConvo) {
        await supabase.from("conversations").update({
          last_message: userMessage.slice(0, 200), last_message_at: new Date().toISOString(),
          unread_count: (conv.unread_count ?? 0) + 1, status: "open",
          lead_id: conv.lead_id ?? lead?.id ?? null, relevance_score: relevanceScore,
          relevance_checked_at: new Date().toISOString(),
        }).eq("id", conv.id);
      }
      const conversationId = conv.id as number;

      await supabase.from("messages").insert({
        conversation_id: conversationId, business_id: businessId, body: userMessage, direction: "inbound",
        channel: "email", status: "delivered", sender_name: verifiedName ?? fromAddress, subject,
        email_source: "outlook", external_message_id: graphMessageId, external_thread_id: msg.conversationId ?? null,
        trust_status: trustStatus, trust_reason: trustReason,
      });

      // ── EM-03 low-relevance short-circuit ──
      if (isLowRelevance) {
        console.log(`microsoft-graph-webhook: low relevance sender ${fromAddress} (score ${relevanceScore}) — saved message, no AI reply`);
        continue;
      }

      // ── EM-04: email_received automation trigger ──
      fetch(`${SUPABASE_URL}/functions/v1/run-automation`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}` },
        body: JSON.stringify({ trigger_type: "email_received", business_id: businessId, payload: { lead_name: verifiedName ?? fromAddress, email: fromAddress, lead_id: lead?.id ?? null } }),
      }).catch((e) => console.error("Automation (email_received):", e));

      if (!(conv.ai_enabled ?? true)) continue;

      const { data: recentMsgs } = await supabase.from("messages").select("body, direction")
        .eq("conversation_id", conversationId).order("created_at", { ascending: false }).limit(10);
      const history = (recentMsgs ?? []).reverse().map((m: any) => ({ role: m.direction === "inbound" ? "user" : "assistant", content: m.body }));

      let aiReply = "";
      const now = new Date();
      const windowResetAt = conv.ai_reply_window_reset_at ? new Date(conv.ai_reply_window_reset_at) : null;
      const windowExpired = !windowResetAt || (now.getTime() - windowResetAt.getTime()) > 24 * 60 * 60 * 1000;
      const currentReplyCount = windowExpired ? 0 : (conv.ai_reply_count_24h ?? 0);
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

      // ── STATE MACHINE (same shape as receive-email / gmail-inbound-webhook) ──
      if (!isBlocked && ci.waiting_for === "name") {
        const suggested = ci.suggested_name as string | null;
        const firstLine = userMessage.split(/\n/)[0].trim();
        const isAffirmative = /^(yes|yep|yeah|correct|sure|yup|right|ok|okay|affirmative|that'?s? ?(me|right|correct)?)\b/i.test(firstLine);
        let capturedName: string | null = null;
        if (suggested && isAffirmative) capturedName = suggested;
        else capturedName = await extractNameFromMessage(userMessage, suggested);

        if (capturedName) {
          const first = firstName(capturedName);
          const leadId = await ensureLeadExists(businessId, fromAddress, capturedName, lead?.id ?? null);
          ci = { ...ci, waiting_for: null, name_collected: true, suggested_name: null };
          verifiedName = capturedName;
          await supabase.from("conversations").update({ contact_name: capturedName, lead_id: leadId, collecting_info: ci, name_verified: true }).eq("id", conversationId);
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
          const leadId = await ensureLeadExists(businessId, fromAddress, fullName, lead?.id ?? null);
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
        const nameVerified = conv.name_verified || !!verifiedName;
        if (!nameVerified) {
          const bizName = biz.business_name ?? "us";
          if (fromName) { aiReply = `Hi, thank you for reaching out to ${bizName}! Am I speaking with ${fromName}?`; ci = { ...ci, waiting_for: "name", suggested_name: fromName }; }
          else { aiReply = `Hi, thank you for reaching out to ${bizName}! Could I get your full name first?`; ci = { ...ci, waiting_for: "name", suggested_name: null }; }
          await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId);
        } else {
          const currentName = verifiedName ?? conv.contact_name;
          const first = firstName(currentName);
          const pendingSlots = conv.pending_booking_slots as Array<{ label: string; start: string; end: string }> | null;
          const intent = await detectIntent(userMessage, history);

          if (pendingSlots?.length && intent.isPickingSlot && intent.slotChoice) {
            const chosen = pendingSlots[intent.slotChoice - 1];
            if (!chosen) { aiReply = `Sorry ${first}, please reply with 1, 2, or 3 to pick a time.`; }
            else {
              const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", fromAddress).maybeSingle();
              const hasPhone = fl?.lead_phone || ci.phone_collected;
              const hasAddr = fl?.lead_address || ci.address_collected;
              if (!hasPhone) { aiReply = `Great choice, ${first}! Before I confirm, could I get your phone number?`; ci = { ...ci, waiting_for: "phone", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else if (!hasAddr) { aiReply = `Almost there! Could I also get your full address, ${first}?`; ci = { ...ci, waiting_for: "address", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else if (!hasLastName(currentName) && !ci.last_name_collected) { aiReply = `Just one more thing — could I get your last name, ${first}?`; ci = { ...ci, waiting_for: "last_name", pending_slot_choice: intent.slotChoice }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
              else {
                const { data: newAppt, error: apptErr } = await supabase.from("appointments").insert({
                  business_id: businessId, calendar_id: biz.default_calendar_id ?? null, appointment_name: `Appointment – ${currentName}`,
                  appointment_type: "Consultation", status: "New", start_date_time: chosen.start, end_date_time: chosen.end,
                  lead_id: fl?.id ?? lead?.id ?? null, lead_name: currentName, lead_phone: fl?.lead_phone ?? "", lead_email: fromAddress,
                  notes: fl?.lead_address ? `Address: ${fl.lead_address}` : "", confirmation_sent: false,
                }).select().maybeSingle();
                if (apptErr) {
                  console.error(`microsoft-graph-webhook: appointment insert failed for conversation ${conversationId}:`, apptErr);
                  aiReply = `Sorry ${first}, something went wrong confirming that time. Someone from our team will reach out shortly to get you booked.`;
                } else {
                  await supabase.from("conversations").update({ pending_booking_slots: null, collecting_info: { ...ci, waiting_for: null } }).eq("id", conversationId);
                  if (fl) await supabase.from("leads").update({ lead_status: "In Conversation", converted_to_appointment: true, appointment_scheduled_at: chosen.start }).eq("id", fl.id);
                  aiReply = `You're all set, ${first}! Booked for ${chosen.label}. We look forward to seeing you!`;
                }
              }
            }
          } else if (intent.wantsBooking) {
            if (!hasLastName(currentName) && !ci.last_name_collected) { aiReply = `I'd love to help you schedule something, ${first}! Before I do, could I get your last name?`; ci = { ...ci, waiting_for: "last_name", booking_requested: true }; await supabase.from("conversations").update({ collecting_info: ci }).eq("id", conversationId); }
            else {
              const { data: fl } = await supabase.from("leads").select("*").eq("business_id", businessId).eq("lead_email", fromAddress).maybeSingle();
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
          ai_reply_window_reset_at: windowExpired ? now.toISOString() : (conv.ai_reply_window_reset_at ?? now.toISOString()),
        }).eq("id", conversationId);
      }

      // ── EM-06: draft vs. autopilot. Abuse-breaker/beta-cap canned
      // messages always send immediately regardless of mode — same rule
      // as receive-email/Gmail.
      const effectiveReplyMode = !isBlocked
        ? (conv.ai_reply_mode_override as string | null) ?? (biz.email_ai_reply_mode as string | null) ?? "autopilot"
        : "autopilot";

      if (effectiveReplyMode === "draft") {
        console.log(`microsoft-graph-webhook: EM-06 draft mode — holding AI reply for review, conversation ${conversationId}`);
        await supabase.from("messages").insert({
          conversation_id: conversationId, business_id: businessId, body: aiReply,
          direction: "outbound", channel: "email", status: "pending_review",
          sender_name: "AI Assistant", sent_via_twiml: true, original_ai_body: aiReply,
          email_source: "outlook",
        });
        // last_message / last_message_at intentionally NOT updated — nothing
        // has gone out yet, same as receive-email's draft-mode branch.
      } else {
        const sent = await sendGraphReply({ accessToken, messageId: graphMessageId, commentText: aiReply });
        await supabase.from("messages").insert({
          conversation_id: conversationId, business_id: businessId, body: aiReply, direction: "outbound",
          channel: "email", status: "delivered", sender_name: "AI Assistant", sent_via_twiml: true,
          email_source: "outlook", external_message_id: sent?.id ?? null, external_thread_id: msg.conversationId ?? null,
        });
        await supabase.from("conversations").update({ last_message: aiReply.slice(0, 200), last_message_at: new Date().toISOString() }).eq("id", conversationId);
        if (lead?.id) await supabase.from("leads").update({ last_message_at: new Date().toISOString() }).eq("id", lead.id);
      }

      if (isNewConvo) {
        fetch(`${SUPABASE_URL}/functions/v1/run-automation`, {
          method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}` },
          body: JSON.stringify({ trigger_type: "new_lead", business_id: businessId, payload: { lead_name: verifiedName ?? fromAddress, email: fromAddress, lead_id: lead?.id ?? null } }),
        }).catch((e) => console.error("Automation:", e));
      }
    }

    return new Response("ok", { status: 202 });
  } catch (e) {
    console.error("microsoft-graph-webhook error:", e);
    return new Response("ok", { status: 200 });
  }
});