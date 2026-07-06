import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Nominatim requires a real, identifying User-Agent — anonymous/generic
// User-Agents get blocked. Update the contact email if it ever changes.
const NOMINATIM_USER_AGENT = "NexaFlow CRM (contact: vantagecaretech@gmail.com)";

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

    const { appointment_id, address } = await req.json();
    if (!appointment_id || !address || typeof address !== "string" || address.trim().length === 0) {
      return new Response(JSON.stringify({ error: "appointment_id and a non-empty address are required" }), { status: 400, headers: corsHeaders });
    }

    // business_id is resolved from the appointment row itself — never trusted
    // from the client — same pattern as send-on-my-way-sms.
    const { data: appointment, error: apptErr } = await supabase
      .from("appointments")
      .select("id, business_id")
      .eq("id", appointment_id)
      .maybeSingle();
    if (apptErr) throw apptErr;
    if (!appointment) {
      return new Response(JSON.stringify({ error: "Appointment not found" }), { status: 404, headers: corsHeaders });
    }
    const businessId: number = appointment.business_id;

    // Caller must either belong to this business, or be a verified superuser.
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

    // Call Nominatim. limit=1 keeps the response small; format=json is the
    // simplest shape to parse.
    const nominatimUrl = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(address.trim())}&format=json&limit=1`;
    const geoRes = await fetch(nominatimUrl, {
      headers: { "User-Agent": NOMINATIM_USER_AGENT },
    });

    if (!geoRes.ok) {
      const errText = await geoRes.text();
      return new Response(JSON.stringify({ error: `Geocoding service error: ${errText}` }), { status: 502, headers: corsHeaders });
    }

    const results = await geoRes.json();
    if (!Array.isArray(results) || results.length === 0) {
      // Address didn't resolve to a coordinate. This is not a hard failure —
      // the appointment save already succeeded — so we report it back
      // clearly rather than throwing, and leave latitude/longitude untouched.
      return new Response(JSON.stringify({ success: false, geocoded: false, message: "Address could not be geocoded" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const lat = parseFloat(results[0].lat);
    const lng = parseFloat(results[0].lon);
    if (Number.isNaN(lat) || Number.isNaN(lng)) {
      return new Response(JSON.stringify({ success: false, geocoded: false, message: "Geocoding service returned invalid coordinates" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { error: updateErr } = await supabase
      .from("appointments")
      .update({ latitude: lat, longitude: lng })
      .eq("id", appointment_id);
    if (updateErr) throw updateErr;

    return new Response(JSON.stringify({ success: true, geocoded: true, latitude: lat, longitude: lng }), {
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