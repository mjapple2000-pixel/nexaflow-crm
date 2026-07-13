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
    const dateRangeDays = parseInt(url.searchParams.get("date_range_days") ?? "30");
    const searchTerm = url.searchParams.get("search")?.trim().toLowerCase() ?? "";
    const businessIdParam = url.searchParams.get("business_id");
    const authHeader = req.headers.get("Authorization");
    // 'all' | 'in_progress' | 'not_started' | 'completed'
    const statusFilter = url.searchParams.get("status_filter") ?? "all";

    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Not authenticated." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 1. Resolve caller's business (session + superuser bypass) ────────────
    const { data: userData, error: userError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Not authenticated." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let businessId: number;
    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    if (profileError || !profile) {
      const { data: superuser } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (superuser && businessIdParam) {
        businessId = parseInt(businessIdParam);
      } else {
        return new Response(JSON.stringify({ error: "Profile not found." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } else {
      businessId = profile.business_id;
    }

    // ── 2. Load completed submissions in the date range ───────────────────────
    const since = new Date(Date.now() - dateRangeDays * 24 * 60 * 60 * 1000).toISOString();

    let submissionsQuery = supabase
      .from("job_form_submissions")
      .select("id, job_form_id, appointment_id, completed_by_profile_id, status, updated_at")
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .gte("updated_at", since)
      .order("updated_at", { ascending: false });

    if (statusFilter === "started") {
      submissionsQuery = submissionsQuery.eq("status", "in_progress");
    } else if (statusFilter !== "all") {
      submissionsQuery = submissionsQuery.eq("status", statusFilter);
    }

    const { data: submissions, error: subError } = await submissionsQuery;

    if (subError) {
      console.error("get-checklists-report submissions error:", subError);
      return new Response(JSON.stringify({ error: "Failed to load submissions." }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const rows = submissions ?? [];
    if (rows.length === 0) {
      return new Response(JSON.stringify({ submissions: [] }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── 3. Batch-load related data ─────────────────────────────────────────────
    const jobFormIds = [...new Set(rows.map((r) => r.job_form_id).filter(Boolean))];
    const profileIds = [...new Set(rows.map((r) => r.completed_by_profile_id).filter(Boolean))];
    const appointmentIds = [...new Set(rows.map((r) => r.appointment_id).filter(Boolean))];

    const [{ data: jobForms }, { data: profiles }, { data: appointments }] = await Promise.all([
      jobFormIds.length
        ? supabase.from("job_forms").select("id, name").in("id", jobFormIds)
        : Promise.resolve({ data: [] }),
      profileIds.length
        ? supabase.from("profiles").select("id, full_name").in("id", profileIds)
        : Promise.resolve({ data: [] }),
      appointmentIds.length
        ? supabase.from("appointments").select("id, appointment_type, lead_name, location, assigned_to").in("id", appointmentIds)
        : Promise.resolve({ data: [] }),
    ]);

    const formsById = Object.fromEntries((jobForms ?? []).map((f) => [f.id, f]));
    const profilesById = Object.fromEntries((profiles ?? []).map((p) => [p.id, p]));
    const appointmentsById = Object.fromEntries((appointments ?? []).map((a) => [a.id, a]));

    // ── 4. Merge + optional search filter (form name or completed-by name) ────
    let merged = rows.map((r) => {
      const form = formsById[r.job_form_id];
      const completedBy = profilesById[r.completed_by_profile_id];
      const appt = appointmentsById[r.appointment_id];
      return {
        submission_id: r.id,
        status: r.status,
        form_name: form?.name ?? "Unknown Form",
        completed_by_name: appt?.assigned_to ?? completedBy?.full_name ?? "—",
        appointment_id: r.appointment_id,
        appointment_type: appt?.appointment_type ?? null,
        lead_name: appt?.lead_name ?? null,
        location: appt?.location ?? null,
        updated_at: r.updated_at,
      };
    });

    if (searchTerm) {
      merged = merged.filter(
        (m) =>
          m.form_name.toLowerCase().includes(searchTerm) ||
          m.completed_by_name.toLowerCase().includes(searchTerm) ||
          (m.lead_name ?? "").toLowerCase().includes(searchTerm)
      );
    }

    return new Response(JSON.stringify({ submissions: merged }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});