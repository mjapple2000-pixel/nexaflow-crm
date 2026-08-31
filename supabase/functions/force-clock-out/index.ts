import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Returns the locked pay_periods row covering this date, or null if the
// week is unlocked / no pay_periods row exists yet for it.
// deno-lint-ignore no-explicit-any
async function getLockedPayPeriod(supabase: any, businessId: number, isoDateTime: string) {
  const dateOnly = isoDateTime.slice(0, 10); // YYYY-MM-DD, UTC date portion
  const { data } = await supabase
    .from("pay_periods")
    .select("id, week_start, week_end, locked_at")
    .eq("business_id", businessId)
    .lte("week_start", dateOnly)
    .gte("week_end", dateOnly)
    .not("locked_at", "is", null)
    .maybeSingle();
  return data;
}

Deno.serve(async (req) => {
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
    const supabaseServiceKey = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08;

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

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { entry_id, business_id: bodyBusinessId } = await req.json();
    if (!entry_id) {
      return new Response(JSON.stringify({ error: "entry_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Superuser bypass — same pattern as get-connect-status. The superuser
    // account intentionally has no profiles row, so business_id must come
    // from the request body instead of a profile lookup when impersonating.
    const { data: suRow } = await supabase
      .from("superusers")
      .select("user_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();
    const isSuperuser = !!suRow;

    let effectiveBusinessId: number | null = null;
    let actorName = "an admin";

    if (isSuperuser) {
      if (!bodyBusinessId) {
        return new Response(JSON.stringify({ error: "business_id is required" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      effectiveBusinessId = bodyBusinessId;
      actorName = "NexaFlow Support";
    } else {
      const { data: profile, error: profileError } = await supabase
        .from("profiles")
        .select("business_id, role, full_name")
        .eq("user_id", userData.user.id)
        .single();

      if (profileError || !profile?.business_id) {
        return new Response(JSON.stringify({ error: "No business association found" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (profile.role !== "owner" && profile.role !== "admin") {
        return new Response(JSON.stringify({ error: "Not authorized" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      effectiveBusinessId = profile.business_id;
      actorName = profile.full_name ?? "an admin";
    }

    // ── Plan-tier gate: Timesheets & Payroll requires Growth+ ──────────
    if (!isSuperuser) {
      const { data: hasTimeTracking, error: gateErr } = await supabase.rpc("check_plan_feature", {
        p_business_id: effectiveBusinessId,
        p_feature: "time_tracking",
      });
      if (gateErr) {
        return new Response(JSON.stringify({ error: "Failed to verify plan access: " + gateErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (!hasTimeTracking) {
        return new Response(JSON.stringify({
          error: "upgrade_required",
          message: "Timesheets & Payroll requires the Growth plan or higher.",
          upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
        }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    const { data: entry, error: entryError } = await supabase
      .from("time_entries")
      .select("*")
      .eq("id", entry_id)
      .eq("business_id", effectiveBusinessId)
      .maybeSingle();

    if (entryError || !entry) {
      return new Response(JSON.stringify({ error: "Time entry not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (entry.status !== "active") {
      return new Response(JSON.stringify({ error: "This entry is not currently active" }), {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Same lock enforcement as edit-timesheet-entry — superusers can still
    // troubleshoot a stuck clock-in through a locked week; everyone else
    // must unlock the week first.
    const lockedPeriod = await getLockedPayPeriod(supabase, effectiveBusinessId!, entry.clocked_in_at);
    if (lockedPeriod && !isSuperuser) {
      return new Response(
        JSON.stringify({
          error: `This week (${lockedPeriod.week_start} to ${lockedPeriod.week_end}) is locked for payroll. Unlock it first to make changes.`,
          locked: true,
        }),
        {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const clockedOutAt = new Date();
    const clockedInAt = new Date(entry.clocked_in_at);
    const durationMinutes = Math.round((clockedOutAt.getTime() - clockedInAt.getTime()) / 60000);

    const noteAddition = `Force clocked out by ${actorName} on ${clockedOutAt.toLocaleString()}.`;
    const combinedNotes = entry.notes ? `${entry.notes}\n${noteAddition}` : noteAddition;

    const { data: updatedEntry, error: updateError } = await supabase
      .from("time_entries")
      .update({
        clocked_out_at: clockedOutAt.toISOString(),
        duration_minutes: durationMinutes,
        status: "completed",
        notes: combinedNotes,
      })
      .eq("id", entry.id)
      .select()
      .single();

    if (updateError) {
      return new Response(JSON.stringify({ error: "Failed to update entry: " + updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true, entry: updatedEntry }), {
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