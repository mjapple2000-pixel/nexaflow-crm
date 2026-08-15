import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08
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

    // ── 2. Touch last_used_at ───────────────────────────────────────────
    supabase
      .from("employee_hub_tokens")
      .update({ last_used_at: new Date().toISOString() })
      .eq("id", hubToken.id)
      .then(() => {});

    // ── 3. Load profile ──────────────────────────────────────────────────
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

    // ── 4. Load business ────────────────────────────────────────────────
    const { data: business, error: businessError } = await supabase
      .from("businesses")
      .select("business_name, require_location_on_clock, gps_tracking_enabled")
      .eq("id", hubToken.business_id)
      .maybeSingle();

    if (businessError) {
      console.error("get-employee-hub-data business lookup error:", businessError);
    }

    // ── 5. Active time entry ─────────────────────────────────────────────
    const { data: activeEntry } = await supabase
      .from("time_entries")
      .select("*")
      .eq("user_id", profile.user_id)
      .eq("status", "active")
      .is("deleted_at", null)
      .maybeSingle();

    // ── 6. Today's assigned appointments ──────────────────────────
    const todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);
    const todayEnd = new Date();
    todayEnd.setHours(23, 59, 59, 999);
    // Completed forms drop off the tech's Past Forms list one week after
    // completion — keeps that list from growing forever for a busy tech.
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

    const { data: appointments, error: apptError } = await supabase
      .from("appointments")
      .select("id, appointment_type, start_date_time, status, lead_name, location, notes")
      .eq("business_id", hubToken.business_id)
      .eq("assigned_to", profile.full_name)
      .gte("start_date_time", todayStart.toISOString())
      .lte("start_date_time", todayEnd.toISOString())
      .order("start_date_time", { ascending: true });

    if (apptError) {
      console.error("get-employee-hub-data appointments lookup error:", apptError);
    }

    // ── 6a2. Appointments with outstanding (non-completed) job forms, any date ──
    const { data: outstandingAppts, error: outstandingApptsError } = await supabase
      .from("appointments")
      .select("id, appointment_type, start_date_time, status, lead_name, location, notes")
      .eq("business_id", hubToken.business_id)
      .eq("assigned_to_profile_id", profile.id);

    if (outstandingApptsError) {
      console.error("get-employee-hub-data outstanding appointments lookup error:", outstandingApptsError);
    }

    const outstandingApptIds = (outstandingAppts ?? []).map((a: any) => a.id);
    let outstandingApptIdsWithOpenForms = new Set<number>();
    if (outstandingApptIds.length > 0) {
      const { data: openSubs, error: openSubsError } = await supabase
        .from("job_form_submissions")
        .select("appointment_id")
        .in("appointment_id", outstandingApptIds)
        .neq("status", "completed")
        .is("deleted_at", null);

      if (openSubsError) {
        console.error("get-employee-hub-data open submissions lookup error:", openSubsError);
      }
      outstandingApptIdsWithOpenForms = new Set((openSubs ?? []).map((s: any) => s.appointment_id));
    }

    const todaysApptIds = new Set((appointments ?? []).map((a: any) => a.id));
    const outstandingApptsById = new Map((outstandingAppts ?? []).map((a: any) => [a.id, a]));
    const extraAppts = [...outstandingApptIdsWithOpenForms]
      .filter((id) => !todaysApptIds.has(id))
      .map((id) => outstandingApptsById.get(id))
      .filter((a): a is NonNullable<typeof a> => a != null);

    const allAppointments = [
      ...(appointments ?? []),
      ...extraAppts.sort((a: any, b: any) =>
        new Date(b.start_date_time ?? 0).getTime() - new Date(a.start_date_time ?? 0).getTime()),
    ];

    // ── 6b. Job forms attached to today's + outstanding appointments ────
    const apptIds = allAppointments.map((a: any) => a.id);
    let jobFormsByAppt = new Map<number, any[]>();
    if (apptIds.length > 0) {
      const { data: submissions, error: subsError } = await supabase
        .from("job_form_submissions")
        .select("id, appointment_id, job_form_id, status, answers, signature_url")
        .in("appointment_id", apptIds)
        .is("deleted_at", null);

      if (subsError) {
        console.error("get-employee-hub-data job_form_submissions lookup error:", subsError);
      }

      const formIds = [...new Set((submissions ?? []).map((s: any) => s.job_form_id))];
      let formsById = new Map<number, any>();
      if (formIds.length > 0) {
        const { data: forms, error: formsError } = await supabase
          .from("job_forms")
          .select("id, name, fields, requires_signature, photo_attachment_markers")
          .in("id", formIds);
        if (formsError) {
          console.error("get-employee-hub-data job_forms lookup error:", formsError);
        }
        formsById = new Map((forms ?? []).map((f: any) => [f.id, f]));
      }

      const submissionIds = (submissions ?? []).map((s: any) => s.id);
      const markerPhotoCounts = new Map<string, number>();
      if (submissionIds.length > 0) {
        const { data: markerPhotos, error: markerPhotosError } = await supabase
          .from("job_form_photo_attachments")
          .select("submission_id, marker_id")
          .in("submission_id", submissionIds)
          .is("deleted_at", null);
        if (markerPhotosError) {
          console.error("get-employee-hub-data marker photos lookup error:", markerPhotosError);
        }
        for (const p of markerPhotos ?? []) {
          const key = `${p.submission_id}:${p.marker_id}`;
          markerPhotoCounts.set(key, (markerPhotoCounts.get(key) ?? 0) + 1);
        }
      }

      function countRequired(form: any, sub: any): { total: number; missing: number } {
        const fields: any[] = form?.fields ?? [];
        const answers = sub.answers ?? {};
        let total = 0;
        let missing = 0;

        for (const f of fields) {
          if (f.required !== true) continue;
          total++;
          const val = answers[f.id];
          let filled: boolean;
          if (f.type === "checkbox") {
            filled = val === true;
          } else if (f.type === "photo") {
            filled = Array.isArray(val) && val.length > 0;
          } else {
            filled = val != null && String(val).trim() !== "";
          }
          if (!filled) missing++;
        }

        if (form?.requires_signature) {
          total++;
          if (!sub.signature_url) missing++;
        }

        const markers: any[] = form?.photo_attachment_markers ?? [];
        for (const m of markers) {
          if (m.required !== true) continue;
          total++;
          const count = markerPhotoCounts.get(`${sub.id}:${m.id}`) ?? 0;
          if (count === 0) missing++;
        }

        return { total, missing };
      }

      jobFormsByAppt = new Map();
      for (const sub of submissions ?? []) {
        const form = formsById.get(sub.job_form_id);
        const { total, missing } = countRequired(form, sub);
        const list = jobFormsByAppt.get(sub.appointment_id) ?? [];
        list.push({
          submission_id: sub.id,
          job_form_id: sub.job_form_id,
          form_name: form?.name ?? "Unknown Form",
          status: sub.status,
          total_required: total,
          missing_required: sub.status === "completed" ? 0 : missing,
        });
        jobFormsByAppt.set(sub.appointment_id, list);
      }
    }

    // ── 6c. Past completed job forms for this tech (any date) ─────────
    const { data: assignedAppts, error: assignedApptsError } = await supabase
      .from("appointments")
      .select("id, appointment_type, lead_name")
      .eq("business_id", hubToken.business_id)
      .eq("assigned_to_profile_id", profile.id);

    if (assignedApptsError) {
      console.error("get-employee-hub-data assigned appointments lookup error:", assignedApptsError);
    }

    const assignedApptIds = (assignedAppts ?? []).map((a: any) => a.id);
    const pastApptsById = new Map((assignedAppts ?? []).map((a: any) => [a.id, a]));

    let pastJobForms: any[] = [];
    if (assignedApptIds.length > 0) {
      const { data: pastSubmissions, error: pastSubsError } = await supabase
        .from("job_form_submissions")
        .select("id, job_form_id, appointment_id, status, updated_at")
        .eq("business_id", hubToken.business_id)
        .in("appointment_id", assignedApptIds)
        .eq("status", "completed")
        .is("deleted_at", null)
        .gte("updated_at", sevenDaysAgo.toISOString())
        .order("updated_at", { ascending: false })
        .limit(30);

      if (pastSubsError) {
        console.error("get-employee-hub-data past submissions lookup error:", pastSubsError);
      }

      if (pastSubmissions && pastSubmissions.length > 0) {
        const pastFormIds = [...new Set(pastSubmissions.map((s: any) => s.job_form_id))];
        const { data: pastForms } = await supabase
          .from("job_forms")
          .select("id, name")
          .in("id", pastFormIds);
        const pastFormsById = new Map((pastForms ?? []).map((f: any) => [f.id, f.name]));

        pastJobForms = pastSubmissions.map((s: any) => {
          const appt = s.appointment_id ? pastApptsById.get(s.appointment_id) : null;
          return {
            submission_id: s.id,
            form_name: pastFormsById.get(s.job_form_id) ?? "Unknown Form",
            appointment_type: appt?.appointment_type ?? null,
            lead_name: appt?.lead_name ?? null,
            completed_at: s.updated_at,
          };
        });
      }
    }

    // ── 7. Today's assigned route (if a dispatcher has built one) ─────
    const routeDateStr = todayStart.toISOString().slice(0, 10);
    const { data: route, error: routeError } = await supabase
      .from("routes")
      .select("id, stops")
      .eq("business_id", hubToken.business_id)
      .eq("assigned_user_id", profile.user_id)
      .eq("route_date", routeDateStr)
      .is("deleted_at", null)
      .maybeSingle();

    if (routeError) {
      console.error("get-employee-hub-data route lookup error:", routeError);
    }

    let routeStops: any[] = [];
    if (route?.stops?.length) {
      const stopApptIds = route.stops
        .map((s: any) => s.appointment_id)
        .filter((id: any) => typeof id === "number");

      const { data: stopAppts, error: stopApptError } = await supabase
        .from("appointments")
        .select("id, appointment_type, lead_name, location, start_date_time")
        .eq("business_id", hubToken.business_id)
        .in("id", stopApptIds);

      if (stopApptError) {
        console.error("get-employee-hub-data route appointments lookup error:", stopApptError);
      }

      const apptById = new Map((stopAppts ?? []).map((a: any) => [a.id, a]));
      routeStops = route.stops.map((s: any) => {
        const appt = apptById.get(s.appointment_id);
        return {
          appointment_id: s.appointment_id,
          sequence: s.sequence,
          appointment_type: appt?.appointment_type ?? null,
          lead_name: appt?.lead_name ?? null,
          location: appt?.location ?? null,
          scheduled_at: appt?.start_date_time ?? null,
        };
      });
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
        route_stops: routeStops,
        appointments: allAppointments.map((a: any) => ({
          id: a.id,
          appointment_type: a.appointment_type,
          scheduled_at: a.start_date_time,
          status: a.status,
          lead_name: a.lead_name,
          lead_address: a.location,
          notes: a.notes,
          job_forms: jobFormsByAppt.get(a.id) ?? [],
        })),
        past_job_forms: pastJobForms,
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