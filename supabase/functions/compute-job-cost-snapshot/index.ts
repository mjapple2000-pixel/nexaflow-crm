import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = "https://rllriopqojaraceytdno.supabase.co";
const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SERVICE_ROLE_KEY = secretKeys.nexaflow_service_role_2026_08 ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
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

    // 3. Find paid invoice revenue for this job.
    // Primary path: invoices.appointment_id — an exact, unambiguous link
    // to this specific job, set when the invoice is created for a job.
    // Fallback path: invoices with no appointment_id but linked to the
    // same lead (invoices.contact_id -> leads.id, locked JG-01 decision)
    // — covers invoices created before this link existed, or invoices
    // genuinely created at the lead level rather than for one job.
    let totalRevenueCents: number | null = null;
    if (appointment_id) {
      const { data: directInvoices } = await supabase
        .from("invoices")
        .select("amount_due")
        .eq("business_id", business_id)
        .eq("appointment_id", appointment_id)
        .eq("status", "paid")
        .filter("deleted_at", "is", null);

      if (directInvoices && directInvoices.length > 0) {
        const totalDue = directInvoices.reduce(
          (sum: number, inv: { amount_due: number }) => sum + (inv.amount_due ?? 0), 0
        );
        totalRevenueCents = Math.round(totalDue * 100);
      } else {
        const { data: appt } = await supabase
          .from("appointments")
          .select("lead_id")
          .eq("id", appointment_id)
          .eq("business_id", business_id)
          .maybeSingle();

        if (appt?.lead_id) {
          const { data: leadInvoices } = await supabase
            .from("invoices")
            .select("amount_due")
            .eq("business_id", business_id)
            .eq("contact_id", appt.lead_id)
            .eq("status", "paid")
            .filter("deleted_at", "is", null)
            .filter("appointment_id", "is", null);

          if (leadInvoices && leadInvoices.length > 0) {
            const totalDue = leadInvoices.reduce(
              (sum: number, inv: { amount_due: number }) => sum + (inv.amount_due ?? 0), 0
            );
            totalRevenueCents = Math.round(totalDue * 100);
          }
        }
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
    return new Response(JSON.stringify({ error: (err as Error).message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});