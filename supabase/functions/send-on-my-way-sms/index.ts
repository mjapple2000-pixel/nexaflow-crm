import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08;
const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: { user }, error: userErr } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
    }

    const { appointment_id } = await req.json();
    if (!appointment_id) {
      return new Response(JSON.stringify({ error: "appointment_id is required" }), { status: 400, headers: corsHeaders });
    }

    // business_id is resolved from the appointment row itself — never trusted from the client
    const { data: appointment, error: apptErr } = await supabase
      .from("appointments")
      .select("id, business_id, on_my_way_sent_at")
      .eq("id", appointment_id)
      .maybeSingle();
    if (apptErr) throw apptErr;
    if (!appointment) {
      return new Response(JSON.stringify({ error: "Appointment not found" }), { status: 404, headers: corsHeaders });
    }
    const businessId: number = appointment.business_id;

    // Caller must either belong to this business, or be a verified superuser
    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", user.id)
      .maybeSingle();

    const { data: superuserRow } = await supabase
      .from("superusers")
      .select("user_id")
      .eq("user_id", user.id)
      .maybeSingle();

    const hasAccess = !!superuserRow || (profile && profile.business_id === businessId);
    if (!hasAccess) {
      return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: corsHeaders });
    }

    // Read the canonical resolved contact info (live lead, or the frozen
    // snapshot if the lead was deleted) from appointment_contact_info —
    // same source of truth appointments_screen.dart already reads from,
    // rather than duplicating the live-vs-frozen precedence logic here.
    // Now that appointments_screen.dart write-throughs phone/name/email
    // edits to the linked lead, this view is always current.
    const { data: contactInfo } = await supabase
      .from("appointment_contact_info")
      .select("resolved_name, resolved_phone")
      .eq("appointment_id", appointment_id)
      .maybeSingle();

    const contactName = contactInfo?.resolved_name ?? null;
    const contactPhone = contactInfo?.resolved_phone ?? null;

    // Plan gate
    const { data: allowed, error: gateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "on_my_way_sms" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "On My Way texts require the Starter plan or above.",
        upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
      }), { status: 403, headers: corsHeaders });
    }

    if (!contactPhone) {
      return new Response(JSON.stringify({ error: "No phone number on file for this appointment" }), { status: 400, headers: corsHeaders });
    }


    const { data: business, error: bizErr } = await supabase
      .from("businesses")
      .select("business_name, ai_phone_number")
      .eq("id", businessId)
      .maybeSingle();
    if (bizErr) throw bizErr;
    if (!business?.ai_phone_number) {
      return new Response(JSON.stringify({ error: "No Twilio number configured for this business" }), { status: 400, headers: corsHeaders });
    }

    const firstName = (contactName || "there").trim().split(/\s+/)[0];
    const smsBody = `Hi ${firstName}, this is ${business.business_name} — we're on our way!`;

    const twilioRes = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_ACCOUNT_SID}/Messages.json`,
      {
        method: "POST",
        headers: {
          Authorization: `Basic ${btoa(`${TWILIO_ACCOUNT_SID}:${TWILIO_AUTH_TOKEN}`)}`,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          To: contactPhone,
          From: business.ai_phone_number,
          Body: smsBody,
        }).toString(),
      }
    );

    if (!twilioRes.ok) {
      const twilioErr = await twilioRes.text();
      return new Response(JSON.stringify({ error: `Twilio error: ${twilioErr}` }), { status: 500, headers: corsHeaders });
    }

    const sentAt = new Date().toISOString();
    const { error: updateErr } = await supabase
      .from("appointments")
      .update({ on_my_way_sent_at: sentAt })
      .eq("id", appointment.id);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ success: true, sent_at: sentAt }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: corsHeaders }
    );
  }
});