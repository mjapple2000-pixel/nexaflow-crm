import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Haversine distance in meters between two lat/lng points.
function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

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

    const { assigned_user_id, route_date } = await req.json();
    if (!assigned_user_id || !route_date) {
      return new Response(JSON.stringify({ error: "assigned_user_id and route_date are required" }), { status: 400, headers: corsHeaders });
    }

    const { data: callerProfile, error: callerErr } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", user.id)
      .maybeSingle();
    if (callerErr) throw callerErr;

    const { data: superuserRow } = await supabase
      .from("superusers")
      .select("user_id")
      .eq("user_id", user.id)
      .maybeSingle();

    const { data: targetProfile, error: targetErr } = await supabase
      .from("profiles")
      .select("business_id, full_name")
      .eq("user_id", assigned_user_id)
      .maybeSingle();
    if (targetErr) throw targetErr;
    if (!targetProfile || !targetProfile.business_id) {
      return new Response(JSON.stringify({ error: "Target team member not found" }), { status: 404, headers: corsHeaders });
    }
    const businessId: number = targetProfile.business_id;

    const hasAccess = !!superuserRow || (callerProfile && callerProfile.business_id === businessId);
    if (!hasAccess) {
      return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: corsHeaders });
    }

    const { data: allowed, error: gateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "route_optimization" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "Route optimization is available on the Growth plan and above.",
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
      return new Response(JSON.stringify({ error: "feature_disabled", message: "GPS tracking / route optimization is not enabled for this business." }), { status: 403, headers: corsHeaders });
    }

    if (!targetProfile.full_name) {
      return new Response(JSON.stringify({ error: "Target team member has no name on profile" }), { status: 400, headers: corsHeaders });
    }

    const dayStart = `${route_date}T00:00:00`;
    const dayEnd = `${route_date}T23:59:59`;
    const { data: appointments, error: apptErr } = await supabase
      .from("appointments")
      .select("id, appointment_name, location, latitude, longitude, start_date_time")
      .eq("business_id", businessId)
      .eq("assigned_to", targetProfile.full_name)
      .gte("start_date_time", dayStart)
      .lte("start_date_time", dayEnd)
      .order("start_date_time");
    if (apptErr) throw apptErr;

    const withCoords = (appointments ?? []).filter(
      (a) => typeof a.latitude === "number" && typeof a.longitude === "number"
    );
    const withoutCoords = (appointments ?? []).filter(
      (a) => !(typeof a.latitude === "number" && typeof a.longitude === "number")
    );

    const ordered: typeof withCoords = [];
    const remaining = [...withCoords];
    if (remaining.length > 0) {
      ordered.push(remaining.shift()!);
      while (remaining.length > 0) {
        const last = ordered[ordered.length - 1];
        let nearestIdx = 0;
        let nearestDist = Infinity;
        for (let i = 0; i < remaining.length; i++) {
          const d = haversineMeters(last.latitude, last.longitude, remaining[i].latitude, remaining[i].longitude);
          if (d < nearestDist) {
            nearestDist = d;
            nearestIdx = i;
          }
        }
        ordered.push(remaining.splice(nearestIdx, 1)[0]);
      }
    }

    const stops = [
      ...ordered.map((a, i) => ({
        appointment_id: a.id,
        sequence: i + 1,
        lat: a.latitude,
        lng: a.longitude,
      })),
      ...withoutCoords.map((a, i) => ({
        appointment_id: a.id,
        sequence: ordered.length + i + 1,
        lat: null,
        lng: null,
      })),
    ];

    const nowIso = new Date().toISOString();
    const { data: route, error: routeErr } = await supabase
      .from("routes")
      .insert({
        business_id: businessId,
        assigned_user_id,
        route_date,
        stops,
        optimized_at: nowIso,
      })
      .select()
      .maybeSingle();
    if (routeErr) throw routeErr;

    return new Response(JSON.stringify({
      success: true,
      route,
      unoptimized_stop_count: withoutCoords.length,
    }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("optimize-route error:", err);
    const details = err && typeof err === "object"
      ? { message: (err as any).message, code: (err as any).code, details: (err as any).details, hint: (err as any).hint }
      : { message: String(err) };
    return new Response(
      JSON.stringify({ error: "Unexpected error", ...details }),
      { status: 500, headers: corsHeaders }
    );
  }
});