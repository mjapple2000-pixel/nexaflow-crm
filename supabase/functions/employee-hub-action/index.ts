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

const MAILGUN_API_KEY = Deno.env.get("MAILGUN_API_KEY") ?? "";
const MAILGUN_DOMAIN = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

// Internal ops alert — for failures that shouldn't ever fail silently
// (e.g. a notification email that never went out). Never throws itself.
const INTERNAL_ALERT_EMAIL = "vantagecaretech@gmail.com";

async function sendInternalAlert(
  source: string,
  businessId: number | null,
  detail: unknown,
  errorMessage: string,
) {
  try {
    await supabase.from("system_alert_log").insert({
      source,
      business_id: businessId,
      detail,
      error_message: errorMessage,
    });
  } catch (logErr) {
    console.error(`sendInternalAlert: failed to write system_alert_log for ${source}:`, logErr);
  }

  if (!MAILGUN_API_KEY) return;
  try {
    const form = new URLSearchParams();
    form.append("from", `NexaFlow Alerts <no-reply@${MAILGUN_DOMAIN}>`);
    form.append("to", INTERNAL_ALERT_EMAIL);
    form.append("subject", `⚠️ NexaFlow Alert: ${source}`);
    form.append("text", `${errorMessage}\n\nDetail: ${JSON.stringify(detail, null, 2)}`);
    await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
  } catch (alertErr) {
    console.error(`sendInternalAlert: failed to send alert email for ${source}:`, alertErr);
  }
}

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
    const {
      token, action, appointment_id, lat, lng, notes, enabled, accuracy, client_timestamp,
      category_id, amount_cents, description, billable, receipt_base64, receipt_filename,
      week_start, week_end,
    } = body;

    if (!token) {
      return new Response(JSON.stringify({ error: "token is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const validActions = ["clock_in", "clock_out", "toggle_location_sharing", "update_location", "add_note", "send_on_my_way", "check_in_at_stop", "log_expense", "start_break", "end_break", "submit_timesheet"];
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

        // ── Check in at a route stop: distinct from the periodic update_location
    // heartbeat — this is an explicit "I've arrived" action tied to a
    // specific appointment, so office staff can see both where a tech is
    // AND which stop they're actually on, not just a raw lat/lng.
    if (action === "check_in_at_stop") {
      if (!appointment_id || lat == null || lng == null) {
        return new Response(JSON.stringify({ error: "appointment_id, lat, and lng are required" }), {
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

      const nowIso = new Date().toISOString();

      const { error: locErr } = await supabase
        .from("team_locations")
        .upsert({
          user_id: callerUserId,
          business_id: businessId,
          latitude: lat,
          longitude: lng,
          accuracy_meters: accuracy ?? null,
          current_appointment_id: appointment_id,
          recorded_at: nowIso,
          updated_at: nowIso,
        }, { onConflict: "user_id" });

      if (locErr) {
        return new Response(JSON.stringify({ error: "Error updating location: " + locErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: checkInErr } = await supabase
        .from("appointments")
        .update({ checked_in_at: nowIso })
        .eq("id", appointment_id);

      if (checkInErr) {
        return new Response(JSON.stringify({ error: "Error recording check-in: " + checkInErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, checked_in_at: nowIso }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Log a job expense from the field — token-authenticated mirror of
    // log-job-expense, which requires a real JWT session the Hub never has.
    // Resolves business_id/profile_id from the hub token (never the
    // client), same category-ownership and appointment-ownership checks
    // as the office-side version, and writes logged_by_profile_id from
    // the token's own profile so the expense is correctly attributed.
    if (action === "log_expense") {
      if (!appointment_id) {
        return new Response(JSON.stringify({ error: "appointment_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!category_id) {
        return new Response(JSON.stringify({ error: "category_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!amount_cents || typeof amount_cents !== "number" || amount_cents <= 0) {
        return new Response(JSON.stringify({ error: "amount_cents must be a positive number" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: allowed, error: gateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "job_costing" });
      if (gateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + gateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!allowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Job Costing requires the Growth plan or above.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
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

      const { data: category, error: categoryError } = await supabase
        .from("expense_categories")
        .select("business_id")
        .eq("id", category_id)
        .maybeSingle();
      if (categoryError || !category || category.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "Invalid category_id" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: expense, error: insertError } = await supabase
        .from("job_expenses")
        .insert({
          business_id: businessId,
          appointment_id,
          category_id,
          amount_cents,
          description: description ?? null,
          billable: billable ?? true,
          logged_by_profile_id: hubToken.profile_id,
          logged_at: new Date().toISOString(),
        })
        .select()
        .single();

      if (insertError) {
        return new Response(JSON.stringify({ error: "Error saving expense: " + insertError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      let receiptPath: string | null = null;
      if (typeof receipt_base64 === "string" && receipt_base64.length > 0) {
        try {
          const bytes = Uint8Array.from(atob(receipt_base64), (c) => c.charCodeAt(0));
          const ext = (typeof receipt_filename === "string" && receipt_filename.includes("."))
            ? receipt_filename.split(".").pop()
            : "jpg";
          const fileName = `${businessId}/${expense.id}/${Date.now()}.${ext}`;
          const { error: uploadError } = await supabase.storage
            .from("job-expense-receipts")
            .upload(fileName, bytes, { contentType: "image/jpeg", upsert: false });
          if (!uploadError) {
            await supabase
              .from("job_expenses")
              .update({ receipt_photo_path: fileName })
              .eq("id", expense.id);
            receiptPath = fileName;
          } else {
            console.error("log_expense receipt upload error:", uploadError.message);
          }
        } catch (e) {
          console.error("log_expense receipt decode error:", e);
        }
      }

      return new Response(JSON.stringify({ success: true, expense: { ...expense, receipt_photo_path: receiptPath } }), {
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

    // ── Start break: stamps is_paid from the business's default_break_paid
    // setting at the moment the break starts — never recomputed later even
    // if the business default changes afterward (same immutability rule
    // used for referral rewards), so a manager who flips the default later
    // doesn't silently rewrite pay for breaks that already happened.
    if (action === "start_break") {
      const { data: active, error: activeError } = await supabase
        .from("time_entries")
        .select("id, status")
        .eq("user_id", callerUserId)
        .in("status", ["active", "on_break"])
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

      if (active.status === "on_break") {
        return new Response(JSON.stringify({ error: "Already on break" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: breakFeatureAllowed, error: breakGateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "time_tracking" });
      if (breakGateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + breakGateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!breakFeatureAllowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheets & Payroll requires the Growth plan or above.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      const { data: bizBreakSettings } = await supabase
        .from("businesses")
        .select("default_break_paid")
        .eq("id", businessId)
        .maybeSingle();

      const nowIso = new Date().toISOString();

      const { data: newBreak, error: breakInsertError } = await supabase
        .from("time_entry_breaks")
        .insert({
          time_entry_id: active.id,
          business_id: businessId,
          started_at: nowIso,
          is_paid: bizBreakSettings?.default_break_paid === true,
        })
        .select()
        .single();

      if (breakInsertError) {
        return new Response(JSON.stringify({ error: "Error starting break: " + breakInsertError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: statusError } = await supabase
        .from("time_entries")
        .update({ status: "on_break" })
        .eq("id", active.id);

      if (statusError) {
        return new Response(JSON.stringify({ error: "Error updating status: " + statusError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, break: newBreak }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Submit for approval (TS-11): employee-triggered, always submits
    // the caller's own timesheet for the period the client computed
    // (same client-computes-boundaries convention get-timesheets and the
    // office Pay Period lock controls already use — this function just
    // trusts and validates week_start/week_end, it never recomputes
    // pay_period_type boundary math itself).
    if (action === "submit_timesheet") {
      if (!week_start || !week_end) {
        return new Response(JSON.stringify({ error: "week_start and week_end are required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (week_end < week_start) {
        return new Response(JSON.stringify({ error: "week_end must be on or after week_start" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: timeTrackingAllowed, error: submitGateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "time_tracking" });
      if (submitGateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + submitGateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!timeTrackingAllowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheets & Payroll requires the Growth plan or above.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      // TS-11: the submit/approve/reject workflow itself is a Pro (or
      // beta) feature — Growth+ still gets plain Timesheets & Payroll
      // (clock in/out, pay rates, lock/unlock), just not this workflow.
      const { data: approvalWorkflowAllowed, error: approvalGateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "timesheet_approval_workflow" });
      if (approvalGateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + approvalGateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!approvalWorkflowAllowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheet submission & approval requires the Pro plan.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      const { data: existingPeriod, error: periodFetchErr } = await supabase
        .from("pay_periods")
        .select("id, week_start, week_end, locked_at")
        .eq("business_id", businessId)
        .eq("week_start", week_start)
        .maybeSingle();

      if (periodFetchErr) {
        return new Response(JSON.stringify({ error: "Failed to look up pay period: " + periodFetchErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      let payPeriodId: number;

      if (existingPeriod) {
        if (existingPeriod.week_end !== week_end) {
          return new Response(
            JSON.stringify({
              error: `A pay period starting ${week_start} already exists with a different end date (${existingPeriod.week_end}). Check the period dates and try again.`,
            }),
            { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        if (existingPeriod.locked_at) {
          return new Response(
            JSON.stringify({ error: "This pay period is already locked and can't accept new submissions.", locked: true }),
            { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
        payPeriodId = existingPeriod.id;
      } else {
        const { data: created, error: createErr } = await supabase
          .from("pay_periods")
          .insert({ business_id: businessId, week_start, week_end })
          .select("id")
          .maybeSingle();

        if (createErr || !created) {
          return new Response(JSON.stringify({ error: "Failed to create pay period: " + (createErr?.message ?? "unknown error") }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        payPeriodId = created.id;
      }

      const { data: existingStatus } = await supabase
        .from("employee_pay_period_status")
        .select("id, status")
        .eq("pay_period_id", payPeriodId)
        .eq("user_id", callerUserId)
        .maybeSingle();

      if (existingStatus?.status === "submitted") {
        return new Response(JSON.stringify({ error: "This timesheet has already been submitted and is awaiting review." }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (existingStatus?.status === "approved") {
        return new Response(JSON.stringify({ error: "This timesheet has already been approved." }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const fromStatus = existingStatus?.status ?? null;
      const nowIso = new Date().toISOString();

      let statusRow;
      if (existingStatus) {
        const { data: updated, error: updateErr } = await supabase
          .from("employee_pay_period_status")
          .update({
            status: "submitted",
            submitted_at: nowIso,
            rejected_at: null,
            rejected_by: null,
            rejection_reason: null,
          })
          .eq("id", existingStatus.id)
          .select()
          .maybeSingle();
        if (updateErr) {
          return new Response(JSON.stringify({ error: "Failed to submit timesheet: " + updateErr.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        statusRow = updated;
      } else {
        const { data: inserted, error: insertErr } = await supabase
          .from("employee_pay_period_status")
          .insert({
            business_id: businessId,
            pay_period_id: payPeriodId,
            user_id: callerUserId,
            status: "submitted",
            submitted_at: nowIso,
          })
          .select()
          .maybeSingle();
        if (insertErr) {
          return new Response(JSON.stringify({ error: "Failed to submit timesheet: " + insertErr.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        statusRow = inserted;
      }

      await supabase.from("pay_period_status_history").insert({
        business_id: businessId,
        pay_period_id: payPeriodId,
        user_id: callerUserId,
        from_status: fromStatus,
        to_status: "submitted",
        changed_by: callerUserId,
      });

      // ── Notify the owner. Never blocks the submission, but a failure
      // here is never silent — system_alert_log + an internal email.
      try {
        const { data: business } = await supabase
          .from("businesses")
          .select("business_name, owner_email, business_email, admin_email")
          .eq("id", businessId)
          .maybeSingle();

        const ownerEmail = business?.owner_email || business?.business_email || business?.admin_email;
        const businessName = business?.business_name || "your business";

        if (!ownerEmail) {
          await sendInternalAlert(
            "employee-hub-action:submit_timesheet:notify-owner",
            businessId,
            { user_id: callerUserId, week_start, week_end },
            "Business has no owner_email/business_email/admin_email on file — submission was recorded but the owner was never notified.",
          );
        } else if (MAILGUN_API_KEY) {
          const employeeName = profile.full_name || "An employee";
          const lines = [
            `${employeeName} just submitted their timesheet for review.`,
            "",
            `Period: ${week_start} to ${week_end}`,
            "",
            "Review it in NexaFlow under Timesheets & Payroll.",
            "",
            `— ${businessName}`,
          ];
          const form = new URLSearchParams();
          form.append("from", `${businessName} <no-reply@${MAILGUN_DOMAIN}>`);
          form.append("to", ownerEmail);
          form.append("subject", `🕒 Timesheet Submitted by ${employeeName}`);
          form.append("text", lines.join("\n"));

          const mailgunRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
            method: "POST",
            headers: {
              "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
              "Content-Type": "application/x-www-form-urlencoded",
            },
            body: form.toString(),
          });

          if (!mailgunRes.ok) {
            const mailgunErrText = await mailgunRes.text();
            await sendInternalAlert(
              "employee-hub-action:submit_timesheet:notify-owner",
              businessId,
              { user_id: callerUserId, week_start, week_end, mailgun_status: mailgunRes.status },
              `Mailgun returned ${mailgunRes.status}: ${mailgunErrText}`,
            );
          }
        }
      } catch (notifyErr) {
        await sendInternalAlert(
          "employee-hub-action:submit_timesheet:notify-owner",
          businessId,
          { user_id: callerUserId, week_start, week_end },
          notifyErr instanceof Error ? notifyErr.message : String(notifyErr),
        );
      }

      return new Response(JSON.stringify({ success: true, status: statusRow }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── End break: closes the open time_entry_breaks row and returns the
    // shift to "active". is_paid is never touched here — it was already
    // stamped at start_break and stays put per the immutability rule above.
    if (action === "end_break") {
      const { data: active, error: activeError } = await supabase
        .from("time_entries")
        .select("id, status")
        .eq("user_id", callerUserId)
        .eq("status", "on_break")
        .is("deleted_at", null)
        .maybeSingle();

      if (activeError) {
        return new Response(JSON.stringify({ error: "Error finding active break: " + activeError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (!active) {
        return new Response(JSON.stringify({ error: "No active break found" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: breakFeatureAllowed, error: breakGateErr } = await supabase
        .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "time_tracking" });
      if (breakGateErr) {
        return new Response(JSON.stringify({ error: "Error checking plan: " + breakGateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!breakFeatureAllowed) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheets & Payroll requires the Growth plan or above.",
        }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }

      const { data: openBreak, error: openBreakError } = await supabase
        .from("time_entry_breaks")
        .select("id")
        .eq("time_entry_id", active.id)
        .is("ended_at", null)
        .is("deleted_at", null)
        .maybeSingle();

      if (openBreakError || !openBreak) {
        return new Response(JSON.stringify({ error: "No open break found for this shift" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const nowIso = new Date().toISOString();

      const { data: closedBreak, error: closeError } = await supabase
        .from("time_entry_breaks")
        .update({ ended_at: nowIso })
        .eq("id", openBreak.id)
        .select()
        .single();

      if (closeError) {
        return new Response(JSON.stringify({ error: "Error ending break: " + closeError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { error: statusError } = await supabase
        .from("time_entries")
        .update({ status: "active" })
        .eq("id", active.id);

      if (statusError) {
        return new Response(JSON.stringify({ error: "Error updating status: " + statusError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, break: closedBreak }), {
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

    // ── Plan-tier gate: Timesheets & Payroll requires Growth+. Reached
    // only by clock_in/clock_out — every other action already returned
    // above. Matches the same check_plan_feature('time_tracking') gate
    // already enforced on get-timesheets, edit-timesheet-entry,
    // force-clock-out, export-timesheets-pdf, pay_periods RLS, and the
    // break actions — clock_in/clock_out were the one path that had
    // never been gated.
    const { data: clockFeatureAllowed, error: clockGateErr } = await supabase
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "time_tracking" });
    if (clockGateErr) {
      return new Response(JSON.stringify({ error: "Error checking plan: " + clockGateErr.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!clockFeatureAllowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "Timesheets & Payroll requires the Growth plan or above.",
      }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
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
        .in("status", ["active", "on_break"])
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
        .in("status", ["active", "on_break"])
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

      if (active.status === "on_break") {
        return new Response(JSON.stringify({ error: "on_break", message: "Please end your break before clocking out." }), {
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