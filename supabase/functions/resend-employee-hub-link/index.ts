import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // ── Caller must be owner/admin of the target's business ───────────────────
    const { data: callerProfile } = await supabase
      .from("profiles")
      .select("business_id, role")
      .eq("user_id", userData.user.id)
      .single();

    if (!callerProfile || (callerProfile.role !== "owner" && callerProfile.role !== "admin")) {
      return new Response(JSON.stringify({ error: "Not authorized" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { profile_id } = await req.json();
    if (!profile_id) {
      return new Response(JSON.stringify({ error: "profile_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: targetProfile, error: targetError } = await supabase
      .from("profiles")
      .select("id, business_id, phone, full_name")
      .eq("id", profile_id)
      .single();

    if (targetError || !targetProfile || targetProfile.business_id !== callerProfile.business_id) {
      return new Response(JSON.stringify({ error: "Team member not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!targetProfile.phone) {
      return new Response(JSON.stringify({ error: "This team member has no phone number on file." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Revoke existing tokens, issue a new one ────────────────────────────────
    await supabase
      .from("employee_hub_tokens")
      .update({ revoked_at: new Date().toISOString() })
      .eq("profile_id", profile_id)
      .is("revoked_at", null);

    const hubToken = crypto.randomUUID();
    const { error: insertError } = await supabase.from("employee_hub_tokens").insert({
      token: hubToken,
      profile_id: targetProfile.id,
      business_id: targetProfile.business_id,
    });

    if (insertError) {
      return new Response(JSON.stringify({ error: "Failed to create hub token: " + insertError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const hubLink = `https://nexaflow-crm.web.app/hub/${hubToken}`;

    const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID")!;
    const authToken = Deno.env.get("TWILIO_AUTH_TOKEN")!;
    const fromPhone = "+18135500158";

    const twilioRes = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
      {
        method: "POST",
        headers: {
          "Authorization": "Basic " + btoa(`${accountSid}:${authToken}`),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          From: fromPhone,
          To: targetProfile.phone,
          Body: `Here's your updated clock in/out link: ${hubLink}`,
        }).toString(),
      }
    );

    if (!twilioRes.ok) {
      const twilioErr = await twilioRes.text();
      return new Response(
        JSON.stringify({ error: "SMS failed to send: " + twilioErr }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(JSON.stringify({ success: true }), {
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