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
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    const { data: profile, error: profileError } = await supabase
      .from("profiles")
      .select("business_id, role, full_name")
      .eq("user_id", userData.user.id)
      .single();

    if (profileError || !profile?.business_id) {
      return new Response(JSON.stringify({ error: "No business association found" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (profile.role !== "owner" && profile.role !== "admin") {
      return new Response(JSON.stringify({ error: "Not authorized" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { entry_id } = await req.json();
    if (!entry_id) {
      return new Response(JSON.stringify({ error: "entry_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: entry, error: entryError } = await supabase
      .from("time_entries")
      .select("*")
      .eq("id", entry_id)
      .eq("business_id", profile.business_id)
      .maybeSingle();

    if (entryError || !entry) {
      return new Response(JSON.stringify({ error: "Time entry not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (entry.status !== "active") {
      return new Response(JSON.stringify({ error: "This entry is not currently active" }), {
        status: 409,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const clockedOutAt = new Date();
    const clockedInAt = new Date(entry.clocked_in_at);
    const durationMinutes = Math.round((clockedOutAt.getTime() - clockedInAt.getTime()) / 60000);

    const noteAddition = `Force clocked out by ${profile.full_name ?? "an admin"} on ${clockedOutAt.toLocaleString()}.`;
    const combinedNotes = entry.notes ? `${entry.notes}\n${noteAddition}` : noteAddition;

    const { data: updatedEntry, error: updateError } = await supabase
      .from("time_entries")
      .update({
        clocked_out_at: clockedOutAt.toISOString(),
        duration_minutes: durationMinutes,
        status: "completed",
        notes: combinedNotes,
      })
      .eq("id", entry.id)
      .select()
      .single();

    if (updateError) {
      return new Response(JSON.stringify({ error: "Failed to update entry: " + updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true, entry: updatedEntry }), {
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