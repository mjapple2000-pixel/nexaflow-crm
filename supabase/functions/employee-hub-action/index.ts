import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08
);

const TWILIO_ACCOUNT_SID = Deno.env.get("TWILIO_ACCOUNT_SID")!;
const TWILIO_AUTH_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;

// Resolves the timestamp to record for a clock action. If the client
// captured its own timestamp at button-press time (used when the request
// had to be queued locally due to no connectivity and retried later),
// that is used instead of "now" — otherwise a tech who clocked in while
// out of cell range would have their time silently recorded as whenever
// the retry finally succeeded, not when they actually pressed the button.
// Bounded to a sane window (max 48h in the past, max 5min in the future
// for clock skew) so a malformed client_timestamp can't corrupt payroll
// data — falls back to server time outside that window.
function resolveClockTimestamp(clientTimestamp: unknown): { iso: string; offline: boolean } {
  const now = new Date();
  if (typeof clientTimestamp === "string") {
    const parsed = new Date(clientTimestamp);
    if (!isNaN(parsed.getTime())) {
      const diffMs = now.getTime() - parsed.getTime();
      const maxPastMs = 48 * 60 * 60 * 1000;
      const maxFutureMs = 5 * 60 * 1000;
      if (diffMs <= maxPastMs && diffMs >= -maxFutureMs) {
        const offline = diffMs > 15000;
        return { iso: parsed.toISOString(), offline };
      }
    }
  }
  return { iso: now.toISOString(), offline: false };
}

// Normalizes a raw phone number to E.164 for Twilio's To field. Twilio
// will happily accept a malformed number like "+8139518523" (a 10-digit
// US number with a "+" but no "1" country code) and silently misparse it
// as country code 81 (Japan), which then fails as an opaque "Short Code"
// error with no hint the real problem is a missing "1". Stripping to
// digits first and re-adding "+1" for any 10-digit number — regardless
// of how it was originally formatted — closes that gap.
function normalizePhoneE164(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { token, action, appointment_id, lat, lng, notes, enabled, accuracy, client_timestamp } = body;

    if (!token) {
      return new Response(JSON.stringify({ error: "token is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["clock_in", "clock_out", "toggle_location_sharing", "update_location", "add_note", "send_on_my_way"];
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
      .select("user_id, full_name")
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

    // ── Add note: tech leaves a note on an appointment from the read-only
    // detail view. Appends rather than overwrites, same pattern as
    // force-clock-out's noteAddition, so a tech's note never silently
    // wipes out anything office staff already wrote there.
    if (action === "add_note") {
      if (!appointment_id || typeof notes !== "string" || notes.trim().length === 0) {
        return new Response(JSON.stringify({ error: "appointment_id and non-empty notes are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: appt, error: apptError } = await supabase
        .from("appointments")
        .select("id, notes")
        .eq("id", appointment_id)
        .eq("business_id", businessId)
        .maybeSingle();

      if (apptError || !appt) {
        return new Response(JSON.stringify({ error: "Appointment not found for this business" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const techName = profile.full_name ?? "Field tech";
      const stamped = `[${techName}, ${new Date().toLocaleString()}]: ${notes.trim()}`;
      const combined = appt.notes ? `${appt.notes}\n${stamped}` : stamped;

      const { error: noteErr } = await supabase
        .from("appointments")
        .update({ notes: combined })
        .eq("id", appointment_id);

      if (noteErr) {
        return new Response(JSON.stringify({ error: "Error saving note: " + noteErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, notes: combined }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Send on-my-way SMS from the Employee Hub — token-authenticated
    // mirror of send-on-my-way-sms, which requires a real JWT session the
    // Hub never has. Resolves business_id from the hub token (never the
    // client), reads contact info from appointment_contact_info (the same
    // live-lead-or-frozen-snapshot source of truth appointments_screen.dart
    // and send-on-my-way-sms both use), and updates on_my_way_sent_at.
    if (action === "send_on_my_way") {
      if (!appointment_id) {
        return new Response(JSON.stringify({ error: "appointment_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: appt, error: apptError } = await supabase
        .from("appointments")
        .select("id")
        .eq("id", appointment_id)
        .eq("business_id", businessId)
        .maybeSingle();

      if (apptError || !appt) {
        return new Response(JSON.stringify({ error: "Appointment not found for this business" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: allowed, error: gateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "on_my_way_sms" });
      if (gateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + gateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!allowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "On My Way texts require the Starter plan or above.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      const { data: contactInfo } = await supabase
        .from("appointment_contact_info")
        .select("resolved_name, resolved_phone")
        .eq("appointment_id", appointment_id)
        .maybeSingle();

      const contactName = contactInfo?.resolved_name ?? null;
      const contactPhone = contactInfo?.resolved_phone ?? null;

      if (!contactPhone) {
        return new Response(JSON.stringify({ error: "No phone number on file for this appointment" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const formattedPhone = normalizePhoneE164(contactPhone);
      if (!formattedPhone) {
        return new Response(JSON.stringify({ error: `Phone number on file (${contactPhone}) isn't a valid 10-digit US number — fix it on the contact before sending.` }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: business, error: bizErr } = await supabase
        .from("businesses")
        .select("business_name, ai_phone_number")
        .eq("id", businessId)
        .maybeSingle();
      if (bizErr || !business?.ai_phone_number) {
        return new Response(JSON.stringify({ error: "No Twilio number configured for this business" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
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
            To: formattedPhone,
            From: business.ai_phone_number,
            Body: smsBody,
          }).toString(),
        }
      );

      if (!twilioRes.ok) {
        const twilioErr = await twilioRes.text();
        return new Response(JSON.stringify({ error: `Twilio error: ${twilioErr}` }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const sentAt = new Date().toISOString();
      const { error: updateErr } = await supabase
        .from("appointments")
        .update({ on_my_way_sent_at: sentAt })
        .eq("id", appointment_id);
      if (updateErr) {
        return new Response(JSON.stringify({ error: "Sent, but failed to record: " + updateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, sent_at: sentAt }), {
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

      const { iso: clockedInIso, offline: clockedInOffline } = resolveClockTimestamp(client_timestamp);

      const { data: newEntry, error: insertError } = await supabase
        .from("time_entries")
        .insert({
          business_id: businessId,
          appointment_id: appointment_id ?? null,
          user_id: callerUserId,
          clocked_in_at: clockedInIso,
          clock_in_lat: lat ?? null,
          clock_in_lng: lng ?? null,
          status: "active",
          recorded_offline: clockedInOffline,
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

      const { iso: clockedOutIso, offline: clockedOutOffline } = resolveClockTimestamp(client_timestamp);
      const clockedOutAt = new Date(clockedOutIso);
      const clockedInAt = new Date(active.clocked_in_at);
      const durationMinutes = Math.round((clockedOutAt.getTime() - clockedInAt.getTime()) / 60000);

      const { data: updatedEntry, error: updateError } = await supabase
        .from("time_entries")
        .update({
          clocked_out_at: clockedOutIso,
          duration_minutes: durationMinutes,
          clock_out_lat: lat ?? null,
          clock_out_lng: lng ?? null,
          notes: notes ?? active.notes,
          status: "completed",
          recorded_offline: active.recorded_offline === true ? true : clockedOutOffline,
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

    return new Response(JSON.stringify({ error: "Unhandled action" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});