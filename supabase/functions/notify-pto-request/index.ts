import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAILGUN_API_KEY = Deno.env.get("MAILGUN_API_KEY") ?? "";
const MAILGUN_DOMAIN = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

const supabaseUrl = "https://rllriopqojaraceytdno.supabase.co";
const supabaseServiceKey = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08;
const supabase = createClient(supabaseUrl, supabaseServiceKey);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Called directly from the employee's own session right after they
    // submit a request — unlike notify-owner (which is cron-secret-only,
    // server-to-server), this needs to authenticate with a real user JWT
    // since the client never holds the cron secret.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
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

    const { pto_request_id } = await req.json();
    if (!pto_request_id) {
      return new Response(JSON.stringify({ error: "pto_request_id required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Pull the request and confirm it actually belongs to the caller —
    // this endpoint only ever notifies about a request the caller just
    // made themselves, not an arbitrary id someone could pass in.
    const { data: request, error: reqErr } = await supabase
      .from("pto_requests")
      .select("id, business_id, profile_id, start_date, end_date, hours_requested, note")
      .eq("id", pto_request_id)
      .maybeSingle();

    if (reqErr || !request) {
      return new Response(JSON.stringify({ error: "PTO request not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: callerProfile } = await supabase
      .from("profiles")
      .select("id, full_name, business_id")
      .eq("user_id", callerUserId)
      .maybeSingle();

    if (!callerProfile || callerProfile.id !== request.profile_id || callerProfile.business_id !== request.business_id) {
      return new Response(JSON.stringify({ error: "Not authorized to notify about this request" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: business } = await supabase
      .from("businesses")
      .select("business_name, owner_email, business_email, admin_email")
      .eq("id", request.business_id)
      .maybeSingle();

    const ownerEmail = business?.owner_email || business?.business_email || business?.admin_email;
    if (!ownerEmail) {
      // Not an error — plenty of test/demo businesses have no owner email
      // configured. Silently skip rather than failing the request submission.
      return new Response(JSON.stringify({ skipped: "no owner email configured" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const businessName = business?.business_name || "your business";
    const employeeName = callerProfile.full_name || "An employee";
    const hours = Number(request.hours_requested ?? 0);

    const lines = [
      `${employeeName} just submitted a PTO request for ${businessName}.`,
      "",
      `Dates: ${request.start_date} to ${request.end_date}`,
      `Hours: ${hours.toFixed(1)}`,
    ];
    if (request.note) lines.push(`Note: ${request.note}`);
    lines.push("", "Review it in NexaFlow under Settings → PTO Policy → Time Off Requests.", "", `— ${businessName}`);

    const form = new URLSearchParams();
    form.append("from", `${businessName} <no-reply@${MAILGUN_DOMAIN}>`);
    form.append("to", ownerEmail);
    form.append("subject", `🏖️ New PTO Request from ${employeeName}`);
    form.append("text", lines.join("\n"));

    const mgRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(`api:${MAILGUN_API_KEY}`),
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });

    if (!mgRes.ok) {
      const mgErr = await mgRes.text();
      console.error("notify-pto-request Mailgun error:", mgErr);
      return new Response(JSON.stringify({ error: "Failed to send notification" }), {
        status: 502,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ sent: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("notify-pto-request error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});