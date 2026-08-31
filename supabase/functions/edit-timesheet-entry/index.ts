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
    const callerUserId = userData.user.id;

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return new Response(JSON.stringify({ error: "Missing request body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const {
      action, // "create" | "update" | "delete"
      entry_id,
      target_user_id,
      clocked_in_at,
      clocked_out_at,
      notes,
      business_id: requestedBusinessId,
    } = body as {
      action?: string;
      entry_id?: number;
      target_user_id?: string;
      clocked_in_at?: string;
      clocked_out_at?: string;
      notes?: string;
      business_id?: number | string;
    };

    if (!action || !["create", "update", "delete"].includes(action)) {
      return new Response(JSON.stringify({ error: "action must be create, update, or delete" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Resolve caller's business + permission, same pattern as get-timesheets ──
    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id, role, permissions")
      .eq("user_id", callerUserId)
      .maybeSingle();

    let businessId: number;
    let canManageTimesheets: boolean;
    let isSuperuserCaller = false;

    if (profile?.business_id) {
      businessId = profile.business_id;
      const perms = (profile.permissions ?? {}) as Record<string, unknown>;
      canManageTimesheets =
        profile.role === "owner" || profile.role === "admin" || perms.manage_timesheets === true;
    } else {
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
      canManageTimesheets = true; // superuser
      isSuperuserCaller = true; // superusers can troubleshoot through a locked week
    }

    if (!canManageTimesheets) {
      return new Response(JSON.stringify({ error: "You do not have permission to manage timesheets" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // edited_by has a FK to profiles(user_id). The superuser account has no
    // profiles row by design, so stamping callerUserId there would violate
    // that FK — fall back to null for superuser-driven edits instead.
    const editedByUserId = profile?.business_id ? callerUserId : null;

    const nowIso = new Date().toISOString();

    // ── DELETE (soft delete) ──────────────────────────────────
    if (action === "delete") {
      if (!entry_id) {
        return new Response(JSON.stringify({ error: "entry_id is required for delete" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: existing, error: fetchError } = await supabase
        .from("time_entries")
        .select("id, business_id, deleted_at, clocked_in_at")
        .eq("id", entry_id)
        .maybeSingle();

      if (fetchError || !existing) {
        return new Response(JSON.stringify({ error: "Entry not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (existing.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "Entry does not belong to your business" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (existing.deleted_at) {
        return new Response(JSON.stringify({ error: "Entry is already deleted" }), {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const lockedPeriod = await getLockedPayPeriod(supabase, businessId, existing.clocked_in_at);
      if (lockedPeriod && !isSuperuserCaller) {
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

      const { data: deleted, error: deleteError } = await supabase
        .from("time_entries")
        .update({ deleted_at: nowIso, edited_by: callerUserId, edited_at: nowIso })
        .eq("id", entry_id)
        .select()
        .maybeSingle();

      if (deleteError) {
        return new Response(JSON.stringify({ error: "Failed to delete entry: " + deleteError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, entry: deleted }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── CREATE and UPDATE both need valid start/end times ─────
    if (!clocked_in_at) {
      return new Response(JSON.stringify({ error: "clocked_in_at is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let durationMinutes: number | null = null;
    if (clocked_out_at) {
      const startMs = new Date(clocked_in_at).getTime();
      const endMs = new Date(clocked_out_at).getTime();
      if (isNaN(startMs) || isNaN(endMs)) {
        return new Response(JSON.stringify({ error: "Invalid date format" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (endMs <= startMs) {
        return new Response(JSON.stringify({ error: "clocked_out_at must be after clocked_in_at" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      durationMinutes = Math.round((endMs - startMs) / 60000);
    }

    // ── CREATE (admin-added missed shift) ──────────────────────
    if (action === "create") {
      if (!target_user_id) {
        return new Response(JSON.stringify({ error: "target_user_id is required for create" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Verify the target employee actually belongs to the caller's business
      const { data: targetProfile } = await supabase
        .from("profiles")
        .select("user_id, business_id")
        .eq("user_id", target_user_id)
        .maybeSingle();

      if (!targetProfile || targetProfile.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "Target team member not found in your business" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const lockedPeriod = await getLockedPayPeriod(supabase, businessId, clocked_in_at);
      if (lockedPeriod && !isSuperuserCaller) {
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

      const { data: created, error: insertError } = await supabase
        .from("time_entries")
        .insert({
          business_id: businessId,
          user_id: target_user_id,
          clocked_in_at: clocked_in_at,
          clocked_out_at: clocked_out_at ?? null,
          duration_minutes: durationMinutes,
          status: "manual",
          notes: notes ?? null,
          edited_by: editedByUserId,
          edited_at: nowIso,
        })
        .select()
        .maybeSingle();

      if (insertError) {
        return new Response(JSON.stringify({ error: "Failed to create entry: " + insertError.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      return new Response(JSON.stringify({ success: true, entry: created }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── UPDATE (correct an existing entry) ─────────────────────
    if (!entry_id) {
      return new Response(JSON.stringify({ error: "entry_id is required for update" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: existing, error: fetchError } = await supabase
      .from("time_entries")
      .select("id, business_id, status, deleted_at, clocked_in_at")
      .eq("id", entry_id)
      .maybeSingle();

    if (fetchError || !existing) {
      return new Response(JSON.stringify({ error: "Entry not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (existing.business_id !== businessId) {
      return new Response(JSON.stringify({ error: "Entry does not belong to your business" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (existing.deleted_at) {
      return new Response(JSON.stringify({ error: "Cannot edit a deleted entry" }), {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const lockedPeriod = await getLockedPayPeriod(supabase, businessId, existing.clocked_in_at);
    if (lockedPeriod && !isSuperuserCaller) {
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

    // If the entry was still "active" (no clock-out) and this edit supplies
    // one, it's now complete. Manual entries stay "manual" either way.
    const newStatus =
      existing.status === "active" && clocked_out_at ? "completed" : existing.status;

    const { data: updated, error: updateError } = await supabase
      .from("time_entries")
      .update({
        clocked_in_at: clocked_in_at,
        clocked_out_at: clocked_out_at ?? null,
        duration_minutes: durationMinutes,
        status: newStatus,
        notes: notes ?? null,
        edited_by: editedByUserId,
        edited_at: nowIso,
      })
      .eq("id", entry_id)
      .select()
      .maybeSingle();

    if (updateError) {
      return new Response(JSON.stringify({ error: "Failed to update entry: " + updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true, entry: updated }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
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