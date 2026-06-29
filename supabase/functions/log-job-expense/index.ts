import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    // Resolve caller's business_id from their JWT — never trust client-supplied value
    const userClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: { user }, error: userErr } = await createClient(SUPABASE_URL, SERVICE_ROLE_KEY)
      .auth.getUser(authHeader.replace("Bearer ", ""));
    if (userErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const { data: profile, error: profErr } = await userClient
      .from("profiles")
      .select("id, business_id")
      .eq("user_id", user.id)
      .maybeSingle();
    if (profErr || !profile) return new Response(JSON.stringify({ error: "Profile not found" }), { status: 403, headers: corsHeaders });

    const businessId: number = profile.business_id;
    const profileId: number = profile.id;

    // Plan gate — Growth tier required
    const { data: allowed, error: gateErr } = await userClient
      .rpc("check_plan_feature", { p_business_id: businessId, p_feature: "job_costing" });
    if (gateErr) throw gateErr;
    if (!allowed) {
      return new Response(JSON.stringify({
        error: "upgrade_required",
        message: "Job Costing is available on the Growth plan and above.",
        upgrade_url: "https://nexaflow-crm.web.app/settings?section=billing",
      }), { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const {
      appointment_id,
      deal_id,
      expense_type,
      amount_cents,
      description,
      logged_at,
      expense_id, // if provided → update existing row
    } = body;

    // Validate anchor
    if (!appointment_id && !deal_id) {
      return new Response(JSON.stringify({ error: "appointment_id or deal_id is required" }), { status: 400, headers: corsHeaders });
    }

    // Validate expense_type
    const validTypes = ["labor", "material", "subcontractor", "other"];
    if (!validTypes.includes(expense_type)) {
      return new Response(JSON.stringify({ error: "Invalid expense_type" }), { status: 400, headers: corsHeaders });
    }

    // Validate amount
    if (!amount_cents || typeof amount_cents !== "number" || amount_cents <= 0) {
      return new Response(JSON.stringify({ error: "amount_cents must be a positive number" }), { status: 400, headers: corsHeaders });
    }

    // Cross-tenant FK integrity check
    if (appointment_id) {
      const { data: appt } = await userClient
        .from("appointments")
        .select("business_id")
        .eq("id", appointment_id)
        .maybeSingle();
      if (!appt || appt.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "appointment not found or access denied" }), { status: 403, headers: corsHeaders });
      }
    }

    if (deal_id) {
      const { data: deal } = await userClient
        .from("deals")
        .select("business_id")
        .eq("id", deal_id)
        .maybeSingle();
      if (!deal || deal.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "deal not found or access denied" }), { status: 403, headers: corsHeaders });
      }
    }

    let result;

    if (expense_id) {
      // Update existing expense — verify it belongs to this business
      const { data: existing } = await userClient
        .from("job_expenses")
        .select("business_id")
        .eq("id", expense_id)
        .maybeSingle();
      if (!existing || existing.business_id !== businessId) {
        return new Response(JSON.stringify({ error: "Expense not found or access denied" }), { status: 403, headers: corsHeaders });
      }

      const { data, error } = await userClient
        .from("job_expenses")
        .update({
          expense_type,
          amount_cents,
          description: description ?? null,
          logged_at: logged_at ?? new Date().toISOString(),
        })
        .eq("id", expense_id)
        .select()
        .single();
      if (error) throw error;
      result = data;
    } else {
      // Insert new expense
      const { data, error } = await userClient
        .from("job_expenses")
        .insert({
          business_id: businessId,
          appointment_id: appointment_id ?? null,
          deal_id: deal_id ?? null,
          expense_type,
          amount_cents,
          description: description ?? null,
          logged_by_profile_id: profileId,
          logged_at: logged_at ?? new Date().toISOString(),
        })
        .select()
        .single();
      if (error) throw error;
      result = data;
    }

    return new Response(JSON.stringify({ success: true, expense: result }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("log-job-expense error:", err);
    return new Response(JSON.stringify({ error: err.message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});