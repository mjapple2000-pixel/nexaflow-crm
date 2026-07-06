import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
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
      .select("id, business_id, lead_id, lead_name, lead_phone, on_my_way_sent_at")
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

    // Prefer the live phone number from the linked lead — appointment.lead_phone
    // is a snapshot taken at booking time and can go stale if the contact's
    // number changes afterward.
    let contactPhone = appointment.lead_phone as string | null;
    if (appointment.lead_id) {
      const { data: lead } = await supabase
        .from("leads")
        .select("lead_phone")
        .eq("id", appointment.lead_id)
        .maybeSingle();
      if (lead?.lead_phone) contactPhone = lead.lead_phone;
    }

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

    const firstName = (appointment.lead_name || "there").trim().split(/\s+/)[0];
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