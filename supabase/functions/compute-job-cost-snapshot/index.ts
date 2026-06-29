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
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const body = await req.json();
    const { appointment_id, deal_id, business_id } = body;

    if (!business_id) {
      return new Response(JSON.stringify({ error: "business_id is required" }), { status: 400, headers: corsHeaders });
    }
    if (!appointment_id && !deal_id) {
      return new Response(JSON.stringify({ error: "appointment_id or deal_id is required" }), { status: 400, headers: corsHeaders });
    }

    // 1. Sum all non-deleted expenses for this job anchor
    let expenseQuery = supabase
      .from("job_expenses")
      .select("amount_cents")
      .eq("business_id", business_id)
      .filter("deleted_at", "is", null);

    if (appointment_id) expenseQuery = expenseQuery.eq("appointment_id", appointment_id);
    else expenseQuery = expenseQuery.eq("deal_id", deal_id);

    const { data: expenses, error: expErr } = await expenseQuery;
    if (expErr) throw expErr;

    const totalExpensesCents: number = (expenses ?? []).reduce(
      (sum: number, e: { amount_cents: number }) => sum + e.amount_cents, 0
    );

    // 2. Pull job_type from appointment if available
    let jobType: string | null = null;
    if (appointment_id) {
      const { data: appt } = await supabase
        .from("appointments")
        .select("job_type")
        .eq("id", appointment_id)
        .eq("business_id", business_id)
        .maybeSingle();
      jobType = appt?.job_type ?? null;
    }

    // 3. Try to find paid invoice revenue (JG-01 integration — nullable until JG-01 ships)
    let totalRevenueCents: number | null = null;
    if (appointment_id) {
      const { data: invoice } = await supabase
        .from("invoices")
        .select("amount_due")
        .eq("business_id", business_id)
        .eq("status", "paid")
        .filter("deleted_at", "is", null)
        .maybeSingle();
      if (invoice?.amount_due) {
        // amount_due is stored in dollars — convert to cents
        totalRevenueCents = Math.round(invoice.amount_due * 100);
      }
    }

    // 4. Compute profit and margin
    const grossProfitCents: number | null = totalRevenueCents !== null
      ? totalRevenueCents - totalExpensesCents
      : null;

    const profitMarginPct: number | null =
      grossProfitCents !== null && totalRevenueCents !== null && totalRevenueCents > 0
        ? Math.round((grossProfitCents / totalRevenueCents) * 10000) / 100
        : null;

    // 5. Upsert snapshot
    const upsertPayload: Record<string, unknown> = {
      business_id,
      appointment_id: appointment_id ?? null,
      deal_id: deal_id ?? null,
      total_expenses_cents: totalExpensesCents,
      total_revenue_cents: totalRevenueCents,
      gross_profit_cents: grossProfitCents,
      profit_margin_pct: profitMarginPct,
      job_type: jobType,
      snapshotted_at: new Date().toISOString(),
    };

    // Determine conflict target for upsert
    const conflictColumn = appointment_id ? "appointment_id" : "deal_id";

    const { data: snapshot, error: upsertErr } = await supabase
      .from("job_revenue_snapshots")
      .upsert(upsertPayload, { onConflict: conflictColumn })
      .select()
      .single();
    if (upsertErr) throw upsertErr;

    return new Response(JSON.stringify({ success: true, snapshot }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("compute-job-cost-snapshot error:", err);
    return new Response(JSON.stringify({ error: err.message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});