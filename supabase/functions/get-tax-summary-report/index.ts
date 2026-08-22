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
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: { user }, error: userErr } = await supabase
      .auth.getUser(authHeader.replace("Bearer ", ""));
    if (userErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const { data: profile, error: profErr } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", user.id)
      .maybeSingle();

    const url = new URL(req.url);

    let businessId: number;
    if (profErr || !profile) {
      // Superuser accounts intentionally have no profiles row. Check the
      // real superusers table (not a hardcoded email) so ANY superuser —
      // including anyone hired later — can use this, not just one account.
      const { data: superuserRow } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", user.id)
        .maybeSingle();

      const businessIdParam = url.searchParams.get("business_id");
      if (superuserRow && businessIdParam) {
        businessId = parseInt(businessIdParam);
      } else {
        return new Response(JSON.stringify({ error: "Profile not found" }), { status: 403, headers: corsHeaders });
      }
    } else {
      businessId = profile.business_id;
    }

    const hasCustomRange = url.searchParams.has("start_date") && url.searchParams.has("end_date");
    let startIso: string;
    let endIso: string;
    if (hasCustomRange) {
      startIso = url.searchParams.get("start_date")!;
      endIso = url.searchParams.get("end_date")!;
    } else {
      const dateRangeDays = parseInt(url.searchParams.get("date_range_days") ?? "30");
      const cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - dateRangeDays);
      startIso = cutoff.toISOString();
      endIso = new Date().toISOString();
    }

    const { data: business } = await supabase
      .from("businesses")
      .select("tax_jurisdiction_name, tax_state_rate, tax_county_rate, tax_city_rate, tax_special_district_rate, default_tax_rate")
      .eq("id", businessId)
      .maybeSingle();

    // "Tax collected" means money actually received — paid invoices only,
    // filtered by paid_at within the requested range.
    const { data: invoices, error: invErr } = await supabase
      .from("invoices")
      .select("id, invoice_number, paid_at, tax_amount, tax_state_amount, tax_county_amount, tax_city_amount, tax_special_district_amount")
      .eq("business_id", businessId)
      .eq("status", "paid")
      .is("deleted_at", null)
      .gte("paid_at", startIso)
      .lte("paid_at", endIso);
    if (invErr) throw invErr;

    const rows = invoices ?? [];

    let stateAmount = 0;
    let countyAmount = 0;
    let cityAmount = 0;
    let specialAmount = 0;
    let totalTaxAmount = 0;

    for (const row of rows) {
      stateAmount += Number(row.tax_state_amount ?? 0);
      countyAmount += Number(row.tax_county_amount ?? 0);
      cityAmount += Number(row.tax_city_amount ?? 0);
      specialAmount += Number(row.tax_special_district_amount ?? 0);
      totalTaxAmount += Number(row.tax_amount ?? 0);
    }

    return new Response(JSON.stringify({
      success: true,
      start_date: startIso,
      end_date: endIso,
      jurisdiction_name: business?.tax_jurisdiction_name ?? null,
      rates: {
        state_rate: business?.tax_state_rate ?? null,
        county_rate: business?.tax_county_rate ?? null,
        city_rate: business?.tax_city_rate ?? null,
        special_district_rate: business?.tax_special_district_rate ?? null,
        combined_rate: business?.default_tax_rate ?? null,
      },
      totals: {
        invoice_count: rows.length,
        state_amount: Math.round(stateAmount * 100) / 100,
        county_amount: Math.round(countyAmount * 100) / 100,
        city_amount: Math.round(cityAmount * 100) / 100,
        special_district_amount: Math.round(specialAmount * 100) / 100,
        total_tax_amount: Math.round(totalTaxAmount * 100) / 100,
      },
      invoices: rows.map((r) => ({
        invoice_number: r.invoice_number,
        paid_at: r.paid_at,
        tax_amount: r.tax_amount,
        state_amount: r.tax_state_amount,
        county_amount: r.tax_county_amount,
        city_amount: r.tax_city_amount,
        special_district_amount: r.tax_special_district_amount,
      })),
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("get-tax-summary-report error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message ?? "Internal error" }), {
      status: 500,
      headers: corsHeaders,
    });
  }
});