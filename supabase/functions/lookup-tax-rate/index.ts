import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!).nexaflow_service_role_2026_08;

const CACHE_MAX_AGE_DAYS = 30;
const TAX_API_BASE = "https://salestaxzip.com/api/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type RateBreakdown = {
  combined: number;
  state: number;
  county: number;
  city: number;
  special: number;
  jurisdictionName: string;
};

async function getCachedRate(supabase: any, zip: string): Promise<RateBreakdown | null> {
  const { data } = await supabase
    .from("tax_rate_zip_lookup")
    .select("state, county, city, state_rate, county_rate, city_rate, special_district_rate, combined_rate, imported_at")
    .eq("zip_code", zip)
    .maybeSingle();

  if (!data) return null;

  const ageMs = Date.now() - new Date(data.imported_at).getTime();
  const ageDays = ageMs / (1000 * 60 * 60 * 24);
  if (ageDays > CACHE_MAX_AGE_DAYS) return null;

  return {
    combined: Number(data.combined_rate),
    state: Number(data.state_rate),
    county: Number(data.county_rate),
    city: Number(data.city_rate),
    special: Number(data.special_district_rate),
    jurisdictionName: [data.city, data.state].filter(Boolean).join(", "),
  };
}

async function fetchLiveRate(zip: string): Promise<RateBreakdown | { error: string }> {
  let resp: Response;
  try {
    resp = await fetch(`${TAX_API_BASE}/rate/${encodeURIComponent(zip)}`);
  } catch (e) {
    return { error: "Tax rate service unreachable" };
  }

  if (resp.status === 404) return { error: "No tax rate data found for this zip code" };
  if (resp.status === 429) return { error: "Tax rate service rate-limited — try again shortly" };
  if (!resp.ok) return { error: `Tax rate service returned ${resp.status}` };

  const body = await resp.json();
  if (!body?.success || !body?.data?.rates) return { error: "Unexpected response from tax rate service" };

  const r = body.data.rates;
  return {
    combined: Number(r.combined) || 0,
    state: Number(r.state) || 0,
    county: Number(r.county) || 0,
    city: Number(r.city) || 0,
    special: Number(r.local) || 0,
    jurisdictionName: [body.data.city, body.data.state].filter(Boolean).join(", "),
  };
}

async function cacheRate(supabase: any, zip: string, rate: RateBreakdown, state: string | null) {
  const [cityPart, statePart] = rate.jurisdictionName.split(",").map((s) => s.trim());
  await supabase.from("tax_rate_zip_lookup").upsert(
    {
      zip_code: zip,
      state: statePart || state || "",
      city: cityPart || null,
      state_rate: rate.state,
      county_rate: rate.county,
      city_rate: rate.city,
      special_district_rate: rate.special,
      combined_rate: rate.combined,
      source: "salestaxzip_live",
      imported_at: new Date().toISOString(),
    },
    { onConflict: "zip_code" },
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Not found", { status: 404, headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");
    if (!jwt) {
      return new Response(JSON.stringify({ error: "Missing auth token" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: userData, error: userErr } = await anonClient.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const serviceClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: profile } = await serviceClient
      .from("profiles")
      .select("business_id, role")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const { data: superuserRow } = await serviceClient
      .from("superusers")
      .select("user_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    const isSuperuser = superuserRow != null;
    const isOwner = profile?.role === "owner";

    let resolvedBusinessId: number | null = null;
    let body: { business_id?: number } = {};
    try {
      body = await req.json();
    } catch (_) {
      // no body sent
    }

    if (profile?.business_id) {
      if (!isOwner && !isSuperuser) {
        return new Response(JSON.stringify({ error: "Not authorized to update tax settings" }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      resolvedBusinessId = profile.business_id;
    } else if (isSuperuser) {
      if (!body.business_id) {
        return new Response(JSON.stringify({ error: "business_id required for superuser session" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const { data: biz } = await serviceClient.from("businesses").select("id").eq("id", body.business_id).maybeSingle();
      if (!biz) {
        return new Response(JSON.stringify({ error: "Business not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      resolvedBusinessId = biz.id;
    } else {
      return new Response(JSON.stringify({ error: "Not authorized to update tax settings" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: business, error: bizErr } = await serviceClient
      .from("businesses")
      .select("id, zip_code, state")
      .eq("id", resolvedBusinessId)
      .maybeSingle();

    if (bizErr || !business) {
      return new Response(JSON.stringify({ error: "Business not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!business.zip_code) {
      return new Response(JSON.stringify({ error: "Business has no zip code on file — set an address first" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let rate = await getCachedRate(serviceClient, business.zip_code);
    let fromCache = true;

    if (!rate) {
      fromCache = false;
      const liveResult = await fetchLiveRate(business.zip_code);
      if ("error" in liveResult) {
        // Live lookup failed — do NOT touch the business's existing tax fields.
        return new Response(JSON.stringify({ success: false, error: liveResult.error }), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      rate = liveResult;
      await cacheRate(serviceClient, business.zip_code, rate, business.state ?? null);
    }

    const { error: updateErr } = await serviceClient
      .from("businesses")
      .update({
        default_tax_rate: rate.combined,
        tax_state_rate: rate.state,
        tax_county_rate: rate.county,
        tax_city_rate: rate.city,
        tax_special_district_rate: rate.special,
        tax_jurisdiction_name: rate.jurisdictionName,
        tax_rate_source: "lookup",
        tax_rate_updated_at: new Date().toISOString(),
      })
      .eq("id", resolvedBusinessId);

    if (updateErr) {
      console.error("Failed to save looked-up tax rate:", updateErr);
      return new Response(JSON.stringify({ error: "Failed to save tax rate" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({ success: true, from_cache: fromCache, rate }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("lookup-tax-rate exception:", e);
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});