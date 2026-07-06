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

    let body: Record<string, string> = {};
    try {
      body = await req.json();
    } catch (_) {
      // no body is fine
    }

    const { start_date, end_date, user_id_filter, business_id: requestedBusinessId } = body;

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("business_id, role, full_name")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let isOwner: boolean;

    if (profile?.business_id) {
      businessId = profile.business_id;
      isOwner = profile.role === "owner" || profile.role === "admin";
    } else {
      // No profile row — check if caller is a verified superuser before
      // trusting any business_id from the request body.
      const { data: superuserRow } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", callerUserId)
        .maybeSingle();

      if (!superuserRow || !requestedBusinessId) {
        return new Response(JSON.stringify({ error: "No business association found" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      businessId = Number(requestedBusinessId);
      isOwner = true; // superuser sees the full team view
    }

    // ── Fetch active entry for the caller ─────────────────────────────────
    const { data: myActiveEntry } = await supabase
      .from("time_entries")
      .select("*")
      .eq("user_id", callerUserId)
      .eq("status", "active")
      .is("deleted_at", null)
      .maybeSingle();

    // ── Fetch all profiles for this business (for name lookup) ────────────
    const { data: teamProfiles } = await supabase
      .from("profiles")
      .select("user_id, full_name, role")
      .eq("business_id", businessId);

    const profileMap: Record<string, string> = {};
    for (const p of (teamProfiles ?? [])) {
      profileMap[p.user_id] = p.full_name ?? "Unknown";
    }

    // ── Build time_entries query ──────────────────────────────────────────
    let query = supabase
      .from("time_entries")
      .select("*")
      .eq("business_id", businessId)
      .is("deleted_at", null)
      .order("clocked_in_at", { ascending: false });

    // Non-owners only see their own entries
    if (!isOwner) {
      query = query.eq("user_id", callerUserId);
    } else if (user_id_filter) {
      query = query.eq("user_id", user_id_filter);
    }

    if (start_date) {
      query = query.gte("clocked_in_at", `${start_date}T00:00:00.000Z`);
    }
    if (end_date) {
      query = query.lte("clocked_in_at", `${end_date}T23:59:59.999Z`);
    }

    const { data: entries, error: entriesError } = await query;

    if (entriesError) {
      return new Response(JSON.stringify({ error: "Failed to fetch entries: " + entriesError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Enrich entries with full_name ──────────────────────────────────────
    const enriched = (entries ?? []).map((e) => ({
      ...e,
      full_name: profileMap[e.user_id] ?? "Unknown",
    }));

    // ── Compute per-member totals (owner view) ─────────────────────────────
    const totals: Record<string, { full_name: string; total_minutes: number; entry_count: number }> = {};
    if (isOwner) {
      for (const e of enriched) {
        if (!totals[e.user_id]) {
          totals[e.user_id] = {
            full_name: e.full_name,
            total_minutes: 0,
            entry_count: 0,
          };
        }
        totals[e.user_id].total_minutes += (e.duration_minutes ?? 0);
        totals[e.user_id].entry_count += 1;
      }
    }

    // ── Flag stale entries (active for 14+ hours) ─────────────────────────
    const now = new Date();
    const enrichedWithStale = enriched.map((e) => {
      if (e.status !== "active") return e;
      const clockedIn = new Date(e.clocked_in_at);
      const hoursElapsed = (now.getTime() - clockedIn.getTime()) / (1000 * 60 * 60);
      return { ...e, is_stale_display: hoursElapsed >= 14 };
    });

    return new Response(
      JSON.stringify({
        success: true,
        is_owner: isOwner,
        my_active_entry: myActiveEntry ?? null,
        entries: enrichedWithStale,
        totals: isOwner ? Object.values(totals) : [],
        team_profiles: isOwner ? (teamProfiles ?? []) : [],
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});