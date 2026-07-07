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
    const body = await req.json();
    const { token, action, appointment_id, lat, lng, notes, enabled, accuracy } = body;

    if (!token) {
      return new Response(JSON.stringify({ error: "token is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["clock_in", "clock_out", "toggle_location_sharing", "update_location"];
    if (!validActions.includes(action)) {
      return new Response(JSON.stringify({ error: "Invalid action" }), {
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

    const businessId = hubToken.business_id;

    // ── 2. Resolve profile / user_id ─────────────────────────────────────────
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("user_id")
      .eq("id", hubToken.profile_id)
      .maybeSingle();

    if (profileError || !profile || !profile.user_id) {
      return new Response(
        JSON.stringify({ error: "Please finish setting up your account first." }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    const callerUserId = profile.user_id;

    if (action === "toggle_location_sharing") {
      if (typeof enabled !== "boolean") {
        return new Response(JSON.stringify({ error: "enabled must be true or false" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const { error: prefErr } = await supabase
        .from("profiles")
        .update({ location_sharing_enabled: enabled })
        .eq("id", hubToken.profile_id);

      if (prefErr) {
        return new Response(JSON.stringify({ error: "Error updating preference: " + prefErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, location_sharing_enabled: enabled }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (action === "update_location") {
      if (lat == null || lng == null) {
        return new Response(JSON.stringify({ error: "lat and lng are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: bizGps } = await supabase
        .from("businesses")
        .select("gps_tracking_enabled")
        .eq("id", businessId)
        .maybeSingle();

      if (!bizGps?.gps_tracking_enabled) {
        return new Response(JSON.stringify({ error: "feature_disabled", message: "GPS tracking is not enabled for this business." }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: profSharing } = await supabase
        .from("profiles")
        .select("location_sharing_enabled")
        .eq("id", hubToken.profile_id)
        .maybeSingle();

      if (!profSharing?.location_sharing_enabled) {
        return new Response(JSON.stringify({ error: "consent_required", message: "Location sharing is turned off." }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: locErr } = await supabase
        .from("team_locations")
        .upsert({
          user_id: callerUserId,
          business_id: businessId,
          latitude: lat,
          longitude: lng,
          accuracy_meters: accuracy ?? null,
          recorded_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        }, { onConflict: "user_id" });

      if (locErr) {
        return new Response(JSON.stringify({ error: "Error updating location: " + locErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 3. Check location requirement ────────────────────────────────────────
    const { data: bizSettings } = await supabase
      .from("businesses")
      .select("require_location_on_clock")
      .eq("id", businessId)
      .maybeSingle();

    const requireLocation = bizSettings?.require_location_on_clock === true;

    if (requireLocation && (lat == null || lng == null)) {
      return new Response(
        JSON.stringify({
          error: "location_required",
          message: `This business requires location on ${action === "clock_in" ? "clock-in" : "clock-out"}. Please allow location access and try again.`,
        }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
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

    // ── 4. Touch token last_used_at ──────────────────────────────────────────
    supabase
      .from("employee_hub_tokens")
      .update({ last_used_at: new Date().toISOString() })
      .eq("id", hubToken.id)
      .then(() => {});

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
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});