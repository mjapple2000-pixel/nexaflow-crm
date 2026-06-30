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
    const { time_entry_id } = await req.json();

    if (!time_entry_id) {
      return new Response(JSON.stringify({ error: "time_entry_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = "https://rllriopqojaraceytdno.supabase.co";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: entry, error: entryError } = await supabase
      .from("time_entries")
      .select("id, business_id, user_id, clocked_in_at")
      .eq("id", time_entry_id)
      .single();

    if (entryError || !entry) {
      return new Response(JSON.stringify({ error: "Time entry not found: " + (entryError?.message ?? "no row") }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: worker, error: workerError } = await supabase
      .from("profiles")
      .select("full_name")
      .eq("user_id", entry.user_id)
      .maybeSingle();

    const workerName = worker?.full_name ?? "A team member";

    const { data: business, error: businessError } = await supabase
      .from("businesses")
      .select("business_name")
      .eq("id", entry.business_id)
      .maybeSingle();

    const businessName = business?.business_name ?? `Business #${entry.business_id}`;

    const { data: owners, error: ownerError } = await supabase
      .from("profiles")
      .select("email, full_name")
      .eq("business_id", entry.business_id)
      .in("role", ["owner", "admin"]);

    if (ownerError) {
      return new Response(JSON.stringify({ error: "Error looking up owner/admin: " + ownerError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let recipients: string[] = [];
    let subject = "";
    let bodyText = "";

    if (owners && owners.length > 0) {
      recipients = owners.map((o) => o.email).filter((e): e is string => !!e);
      subject = `Forgotten clock-out: ${workerName} at ${businessName}`;
      bodyText = `${workerName} clocked in at ${entry.clocked_in_at} and has not clocked out after 14+ hours. Please review and correct this entry in Timesheets.`;
    }

    if (recipients.length === 0) {
      const { data: businessOwnerEmail } = await supabase
        .from("businesses")
        .select("owner_email")
        .eq("id", entry.business_id)
        .maybeSingle();

      if (businessOwnerEmail?.owner_email) {
        recipients = [businessOwnerEmail.owner_email];
        subject = `Forgotten clock-out: ${workerName} at ${businessName}`;
        bodyText = `${workerName} clocked in at ${entry.clocked_in_at} and has not clocked out after 14+ hours. Please review and correct this entry in Timesheets.`;
      }
    }

    if (recipients.length === 0) {
      recipients = ["vantagecaretech@gmail.com"];
      subject = `No owner/admin found — stale clock-in unflagged for business #${entry.business_id}`;
      bodyText = `A stale clock-in was detected for ${businessName} (business_id: ${entry.business_id}), but no profile with role 'owner' or 'admin' exists for this business, and businesses.owner_email is also empty, so the actual business could not be notified. Time entry id: ${entry.id}, user_id: ${entry.user_id}, clocked in at ${entry.clocked_in_at}. Please assign an owner role or set owner_email for this business.`;
    }

    const mailgunDomain = Deno.env.get("MAILGUN_DOMAIN")!;
    const mailgunApiKey = Deno.env.get("MAILGUN_API_KEY")!;

    const results = [];
    for (const recipient of recipients) {
      const formData = new URLSearchParams();
      formData.append("from", `NexaFlow <noreply@${mailgunDomain}>`);
      formData.append("to", recipient);
      formData.append("subject", subject);
      formData.append("text", bodyText);

      const mgResponse = await fetch(`https://api.mailgun.net/v3/${mailgunDomain}/messages`, {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`api:${mailgunApiKey}`),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: formData,
      });

      const mgResult = await mgResponse.json();
      results.push({ recipient, status: mgResponse.status, result: mgResult });
    }

    return new Response(JSON.stringify({ success: true, notified: recipients, results }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: "Unexpected error: " + (err instanceof Error ? err.message : String(err)) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});