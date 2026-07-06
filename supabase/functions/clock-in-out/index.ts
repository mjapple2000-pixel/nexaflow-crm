import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = "https://rllriopqojaraceytdno.supabase.co";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const supabaseAuth = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userError } = await supabaseAuth.auth.getUser();
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid or expired session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const callerUserId = userData.user.id;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("business_id, role")
      .eq("user_id", callerUserId)
      .single();

    if (profileError || !profile || !profile.business_id) {
      return new Response(JSON.stringify({ error: "No business association found for this user" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const businessId = profile.business_id;

    const { data: allowed, error: gateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "time_tracking" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "Time tracking is available on the Growth plan and above.",
        upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
      }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const body = await req.json();
    const { action, appointment_id, lat, lng, notes } = body;

    if (action !== "clock_in" && action !== "clock_out") {
      return new Response(JSON.stringify({ error: "action must be 'clock_in' or 'clock_out'" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Check location requirement ────────────────────────────────────────
    const { data: bizSettings } = await supabase
      .from("businesses")
      .select("require_location_on_clock")
      .eq("id", businessId)
      .maybeSingle();

    const requireLocation = bizSettings?.require_location_on_clock === true;

    if (requireLocation && action === "clock_in" && (lat == null || lng == null)) {
      return new Response(JSON.stringify({ error: "location_required", message: "This business requires location on clock-in. Please allow location access and try again." }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (requireLocation && action === "clock_out" && (lat == null || lng == null)) {
      return new Response(JSON.stringify({ error: "location_required", message: "This business requires location on clock-out. Please allow location access and try again." }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "clock_in" && appointment_id) {
      const { data: appt, error: apptError } = await supabase
        .from("appointments")
        .select("id")
        .eq("id", appointment_id)
        .eq("business_id", businessId)
        .maybeSingle();

      if (apptError) {
        return new Response(JSON.stringify({ error: "Error validating appointment: " + apptError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (!appt) {
        return new Response(JSON.stringify({ error: "Appointment not found for this business" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    if (action === "clock_in") {
      const { data: existing, error: existingError } = await supabase
        .from("time_entries")
        .select("id")
        .eq("user_id", callerUserId)
        .eq("status", "active")
        .is("deleted_at", null)
        .maybeSingle();

      if (existingError) {
        return new Response(JSON.stringify({ error: "Error checking existing clock-in: " + existingError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (existing) {
        return new Response(JSON.stringify({ error: "Already clocked in", existing_entry_id: existing.id }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: newEntry, error: insertError } = await supabase
        .from("time_entries")
        .insert({
          business_id: businessId,
          appointment_id: appointment_id ?? null,
          user_id: callerUserId,
          clocked_in_at: new Date().toISOString(),
          clock_in_lat: lat ?? null,
          clock_in_lng: lng ?? null,
          status: "active",
        })
        .select()
        .single();

      if (insertError) {
        return new Response(JSON.stringify({ error: "Error creating time entry: " + insertError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, entry: newEntry }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "clock_out") {
      const { data: active, error: activeError } = await supabase
        .from("time_entries")
        .select("*")
        .eq("user_id", callerUserId)
        .eq("status", "active")
        .is("deleted_at", null)
        .maybeSingle();

      if (activeError) {
        return new Response(JSON.stringify({ error: "Error finding active clock-in: " + activeError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (!active) {
        return new Response(JSON.stringify({ error: "No active clock-in found" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const clockedOutAt = new Date();
      const clockedInAt = new Date(active.clocked_in_at);
      const durationMinutes = Math.round((clockedOutAt.getTime() - clockedInAt.getTime()) / 60000);

      const { data: updatedEntry, error: updateError } = await supabase
        .from("time_entries")
        .update({
          clocked_out_at: clockedOutAt.toISOString(),
          duration_minutes: durationMinutes,
          clock_out_lat: lat ?? null,
          clock_out_lng: lng ?? null,
          notes: notes ?? active.notes,
          status: "completed",
        })
        .eq("id", active.id)
        .select()
        .single();

      if (updateError) {
        return new Response(JSON.stringify({ error: "Error updating time entry: " + updateError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, entry: updatedEntry }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  } catch (err) {
    return new Response(JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});