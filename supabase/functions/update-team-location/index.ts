import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

    const { latitude, longitude, accuracy_meters, heading, speed_mps, recorded_at } = await req.json();
    if (typeof latitude !== "number" || typeof longitude !== "number") {
      return new Response(JSON.stringify({ error: "latitude and longitude are required numbers" }), { status: 400, headers: corsHeaders });
    }

    // business_id is always resolved from the caller's own profile — a user
    // can only ever update their own location, never someone else's, so
    // there is no superuser-impersonation case to handle here.
    const { data: profile, error: profileErr } = await supabase
      .from("profiles")
      .select("business_id, location_sharing_enabled")
      .eq("user_id", user.id)
      .maybeSingle();
    if (profileErr) throw profileErr;
    if (!profile || !profile.business_id) {
      return new Response(JSON.stringify({ error: "No business found for this user" }), { status: 400, headers: corsHeaders });
    }
    const businessId: number = profile.business_id;

    const { data: allowed, error: gateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "gps_tracking" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "GPS tracking is available on the Growth plan and above.",
        upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
      }), { status: 403, headers: corsHeaders });
    }

    const { data: business, error: bizErr } = await supabase
      .from("businesses")
      .select("gps_tracking_enabled")
      .eq("id", businessId)
      .maybeSingle();
    if (bizErr) throw bizErr;
    if (!business?.gps_tracking_enabled) {
      return new Response(JSON.stringify({ error: "feature_disabled", message: "GPS tracking is not enabled for this business." }), { status: 403, headers: corsHeaders });
    }

    if (!profile.location_sharing_enabled) {
      return new Response(JSON.stringify({ error: "consent_required", message: "Location sharing is not enabled for this account." }), { status: 403, headers: corsHeaders });
    }

    const nowIso = new Date().toISOString();
    const { error: upsertErr } = await supabase
      .from("team_locations")
      .upsert({
        user_id: user.id,
        business_id: businessId,
        latitude,
        longitude,
        accuracy_meters: accuracy_meters ?? null,
        heading: heading ?? null,
        speed_mps: speed_mps ?? null,
        recorded_at: recorded_at ?? nowIso,
        updated_at: nowIso,
      }, { onConflict: "user_id" });
    if (upsertErr) throw upsertErr;

    return new Response(JSON.stringify({ success: true, updated_at: nowIso }), {
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