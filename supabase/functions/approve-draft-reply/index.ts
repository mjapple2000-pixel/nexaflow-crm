import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKeys.nexaflow_service_role_2026_08 ?? ""
);

const OUTBOUND_EMAIL_SEND_URL = `${Deno.env.get("SUPABASE_URL")}/functions/v1/outbound-email-send`;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // ── Verify the caller's own session token — approved_by is an audit
    // field, so it must come from a server-verified identity, never a
    // client-supplied profile_id. Platform verify_jwt stays off per
    // standing convention; this is the manual equivalent, same pattern
    // as gmail-oauth-connect / create-connect-account reading Authorization.
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) {
      return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid or expired session" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("id, business_id, full_name")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    // Superuser has no profiles row by design — approving/discarding a
    // draft is a business-operator action, so this intentionally requires
    // a real profile rather than special-casing the superuser bypass.
    if (!profile) {
      return new Response(JSON.stringify({ error: "No profile found for this account" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { message_id, edited_body } = await req.json();
    if (!message_id) {
      return new Response(JSON.stringify({ error: "message_id is required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: message, error: msgErr } = await supabase
      .from("messages")
      .select("id, conversation_id, business_id, body, status")
      .eq("id", message_id)
      .maybeSingle();

    if (msgErr || !message) {
      return new Response(JSON.stringify({ error: "Message not found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Cross-tenant guard — the approving profile must belong to the same
    // business the draft belongs to.
    if (message.business_id !== profile.business_id) {
      return new Response(JSON.stringify({ error: "Not authorized for this business" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (message.status !== "pending_review") {
      return new Response(JSON.stringify({ error: `Message is not pending review (status: ${message.status})` }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: conversation } = await supabase
      .from("conversations")
      .select("id, contact_email, lead_id")
      .eq("id", message.conversation_id)
      .maybeSingle();

    if (!conversation?.contact_email) {
      return new Response(JSON.stringify({ error: "Conversation has no contact email on file" }), {
        status: 422, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const finalBody = (edited_body?.trim() || message.body) as string;

    // ── Reuse outbound-email-send's existing Gmail-vs-Mailgun routing,
    // threading, and subject resolution — never reimplement that here.
    const sendRes = await fetch(OUTBOUND_EMAIL_SEND_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        to: conversation.contact_email,
        body: finalBody,
        conversation_id: conversation.id,
      }),
    });

    if (!sendRes.ok) {
      const errBody = await sendRes.text();
      console.error("approve-draft-reply: outbound-email-send failed:", errBody);
      return new Response(JSON.stringify({ error: "Failed to send email" }), {
        status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const nowIso = new Date().toISOString();

    await supabase.from("messages").update({
      body: finalBody,
      status: "delivered",
      approved_by: profile.id,
      approved_at: nowIso,
    }).eq("id", message.id);

    await supabase.from("conversations").update({
      last_message: finalBody.slice(0, 200),
      last_message_at: nowIso,
    }).eq("id", conversation.id);

    if (conversation.lead_id) {
      await supabase.from("leads").update({ last_message_at: nowIso }).eq("id", conversation.lead_id);
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    console.error("approve-draft-reply error:", errMsg);
    return new Response(JSON.stringify({ error: errMsg }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});