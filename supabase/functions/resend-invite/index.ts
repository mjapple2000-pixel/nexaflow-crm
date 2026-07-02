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

    const supabaseUrl = "https://rllriopqojaraceytdno.supabase.co";
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
      .select("id, email, full_name, business_id")
      .eq("id", profile_id)
      .single();

    if (targetError || !targetProfile || targetProfile.business_id !== callerProfile.business_id) {
      return new Response(JSON.stringify({ error: "Team member not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const linkRes = await fetch(`${supabaseUrl}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        type: "invite",
        email: targetProfile.email,
        options: { redirect_to: "https://nexaflow.app/login" },
      }),
    });

    const linkData = await linkRes.json();
    const inviteLink =
      linkData?.action_link ??
      linkData?.properties?.action_link ??
      linkData?.data?.properties?.action_link ??
      "";

    if (!linkRes.ok || !inviteLink) {
      return new Response(
        JSON.stringify({ error: linkData?.msg || linkData?.message || "Failed to generate invite link" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const mailgunKey = Deno.env.get("MAILGUN_API_KEY") ?? "";
    const mailgunDomain = Deno.env.get("MAILGUN_DOMAIN") ?? "mail.vantagecaretech.com";

    if (mailgunKey) {
      const mgForm = new URLSearchParams();
      mgForm.append("from", `NexaFlow <no-reply@${mailgunDomain}>`);
      mgForm.append("to", targetProfile.email);
      mgForm.append("subject", "Your invite link (resent)");
      mgForm.append(
        "html",
        `<p>Hi ${targetProfile.full_name ?? "there"},</p><p>Here's your invite link again:</p><p><a href="${inviteLink}">Click here to set up your account</a></p>`
      );

      const mgRes = await fetch(`https://api.mailgun.net/v3/${mailgunDomain}/messages`, {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`api:${mailgunKey}`),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: mgForm.toString(),
      });

      if (!mgRes.ok) {
        const mgErr = await mgRes.text();
        return new Response(JSON.stringify({ error: "Mailgun send failed: " + mgErr }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
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