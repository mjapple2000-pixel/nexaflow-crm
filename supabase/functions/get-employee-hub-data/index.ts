import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get("token");

    if (!token) {
      return new Response(JSON.stringify({ error: "token is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve token ─────────────────────────────────────────────────────
    const { data: hubToken, error: tokenError } = await supabase
      .from("employee_hub_tokens")
      .select("id, profile_id, business_id, revoked_at")
      .eq("token", token)
      .maybeSingle();

    if (tokenError || !hubToken || hubToken.revoked_at) {
      return new Response(JSON.stringify({ error: "This link is no longer valid." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 2. Touch last_used_at ────────────────────────────────────────────────
    supabase
      .from("employee_hub_tokens")
      .update({ last_used_at: new Date().toISOString() })
      .eq("id", hubToken.id)
      .then(() => {});

    // ── 3. Load profile ──────────────────────────────────────────────────────
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("id, user_id, full_name, role, location_sharing_enabled")
      .eq("id", hubToken.profile_id)
      .maybeSingle();

    if (profileError || !profile) {
      return new Response(JSON.stringify({ error: "Team member not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!profile.user_id) {
      return new Response(
        JSON.stringify({ needs_setup: true, full_name: profile.full_name }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ── 4. Load business ─────────────────────────────────────────────────────
    const { data: business, error: businessError } = await supabase
      .from("businesses")
      .select("business_name, require_location_on_clock, gps_tracking_enabled")
      .eq("id", hubToken.business_id)
      .maybeSingle();

    if (businessError) {
      console.error("get-employee-hub-data business lookup error:", businessError);
    }

    // ── 5. Active time entry ─────────────────────────────────────────────────
    const { data: activeEntry } = await supabase
      .from("time_entries")
      .select("*")
      .eq("user_id", profile.user_id)
      .eq("status", "active")
      .is("deleted_at", null)
      .maybeSingle();

    // ── 6. Today's assigned appointments ────────────────────────────────────
    const todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);
    const todayEnd = new Date();
    todayEnd.setHours(23, 59, 59, 999);

    const { data: appointments, error: apptError } = await supabase
      .from("appointments")
      .select("id, appointment_type, start_date_time, status, lead_name, location")
      .eq("business_id", hubToken.business_id)
      .eq("assigned_to", profile.full_name)
      .gte("start_date_time", todayStart.toISOString())
      .lte("start_date_time", todayEnd.toISOString())
      .order("start_date_time", { ascending: true });

    if (apptError) {
      console.error("get-employee-hub-data appointments lookup error:", apptError);
    }

    return new Response(
      JSON.stringify({
        needs_setup: false,
        full_name: profile.full_name,
        business_name: business?.business_name ?? "",
        require_location_on_clock: business?.require_location_on_clock === true,
        gps_tracking_enabled: business?.gps_tracking_enabled === true,
        location_sharing_enabled: profile.location_sharing_enabled === true,
        active_entry: activeEntry ?? null,
        appointments: (appointments ?? []).map((a: any) => ({
          id: a.id,
          appointment_type: a.appointment_type,
          scheduled_at: a.start_date_time,
          status: a.status,
          lead_name: a.lead_name,
          lead_address: a.location,
        })),
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});