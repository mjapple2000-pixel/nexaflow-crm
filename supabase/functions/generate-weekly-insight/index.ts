import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKeys.nexaflow_service_role_2026_08 ?? ""
);

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  // Preflight — this function is now called directly from Flutter Web
  // (the on-demand refresh button), not just cron/server-to-server, so it
  // needs to handle the browser's CORS preflight like every other
  // browser-callable function in this codebase (see submit-booking).
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Two request modes: cron (bulk, shared-secret auth — see
  // process-scheduled-automations for the original rationale) or
  // on-demand (single business, real user JWT auth).
  const providedSecret = req.headers.get("x-cron-secret") ?? "";
  const isCronRequest = !!CRON_SECRET && providedSecret === CRON_SECRET;

  let singleBusinessId: number | null = null;

  if (!isCronRequest) {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // business_id is resolved server-side from the caller's own profile —
    // never trusted from the client — except for a confirmed superuser
    // impersonating a business, matching the bypass pattern used
    // throughout this codebase's RLS policies.
    const { data: profile } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    if (profile?.business_id) {
      singleBusinessId = profile.business_id as number;
    } else {
      const { data: superuserRow } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (!superuserRow) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const body = await req.json().catch(() => ({} as any));
      if (!body.business_id) {
        return new Response(
          JSON.stringify({ error: "business_id required for superuser refresh" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      singleBusinessId = Number(body.business_id);
    }
  }

  try {
    // ── 1. Determine which business(es) to process — cron processes
    // every business (eligibility checked below via check_plan_feature),
    // on-demand processes exactly one, already resolved above.
    let candidateBusinesses: any[];

    if (isCronRequest) {
      const { data: allBusinesses, error: bizErr } = await supabase
        .from("businesses")
        .select("id, business_name, timezone");
      if (bizErr) throw new Error(`Fetch businesses: ${bizErr.message}`);
      candidateBusinesses = allBusinesses ?? [];
    } else {
      const { data: singleBusiness, error: bizErr } = await supabase
        .from("businesses")
        .select("id, business_name, timezone, weekly_insight_generated_at")
        .eq("id", singleBusinessId)
        .maybeSingle();
      if (bizErr) throw new Error(`Fetch business: ${bizErr.message}`);
      if (!singleBusiness) {
        return new Response(JSON.stringify({ error: "Business not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // 24h on-demand rate limit — cron-generated insights count too,
      // since weekly_insight_generated_at is updated by either path.
      if (singleBusiness.weekly_insight_generated_at) {
        const lastGenerated = new Date(singleBusiness.weekly_insight_generated_at);
        const hoursAgo = (Date.now() - lastGenerated.getTime()) / (1000 * 60 * 60);
        if (hoursAgo < 24) {
          return new Response(
            JSON.stringify({
              error: "Insight was already refreshed recently. Try again later.",
              hours_until_next_refresh: Math.ceil(24 - hoursAgo),
            }),
            { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
          );
        }
      }

      candidateBusinesses = [singleBusiness];
    }

    console.log(`generate-weekly-insight: fetched ${candidateBusinesses.length} candidate business(es)`);

    const eligible: any[] = [];
    for (const b of candidateBusinesses) {
      const { data: hasAccess, error: featureErr } = await supabase.rpc("check_plan_feature", {
        p_business_id: b.id,
        p_feature: "ai_dashboard_insights",
      });
      if (featureErr) {
        console.error(`check_plan_feature failed for business ${b.id}: ${featureErr.message}`);
        continue;
      }
      if (hasAccess) eligible.push(b);
    }

    console.log(`generate-weekly-insight: ${eligible.length} eligible businesses`);

    if (!isCronRequest && eligible.length === 0) {
      return new Response(JSON.stringify({ error: "This feature is not available on your current plan" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const weekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
    const results: Array<{ business_id: number; status: string; error?: string }> = [];

    for (const business of eligible) {
      try {
        const businessId = business.id as number;

        // ── 2. Pull 7-day data scoped to this business ─────────

        const [leadsRes, apptsRes, convosRes, dealsRes, tasksRes] = await Promise.all([
          supabase
            .from("leads")
            .select("id, lead_name, lead_status, source, created_at, converted_to_appointment")
            .eq("business_id", businessId)
            .gte("created_at", weekAgo)
            .is("deleted_at", null),

          supabase
            .from("appointments")
            .select("id, appointment_name, status, start_date_time, appointment_type")
            .eq("business_id", businessId)
            .gte("start_date_time", weekAgo)
            .is("deleted_at", null),

          supabase
            .from("conversations")
            .select("id, status, unread_count, channel, created_at")
            .eq("business_id", businessId)
            .gte("created_at", weekAgo)
            .is("deleted_at", null),

          // Deals and tasks are current-state snapshots, not "created this
          // week" activity — pipeline value and overdue tasks matter as of
          // right now, same as how dashboard_screen.dart reads them. No
          // date-range filter on these two, matching that pattern.
          supabase
            .from("deals")
            .select("id, value, status, stage_id")
            .eq("business_id", businessId)
            .eq("status", "open"),

          supabase
            .from("tasks")
            .select("id, status, due_date")
            .eq("business_id", businessId),
        ]);

        const leads = leadsRes.data ?? [];
        const appts = apptsRes.data ?? [];
        const convos = convosRes.data ?? [];
        const deals = dealsRes.data ?? [];
        const tasks = tasksRes.data ?? [];

        // ── 3. Build summary stats for the prompt ─────────────
        const totalLeads = leads.length;
        const convertedLeads = leads.filter((l: any) => l.converted_to_appointment).length;
        const leadsByStatus: Record<string, number> = {};
        for (const l of leads) {
          const s = l.lead_status ?? "Unknown";
          leadsByStatus[s] = (leadsByStatus[s] ?? 0) + 1;
        }
        const leadsBySource: Record<string, number> = {};
        for (const l of leads) {
          const s = l.source ?? "Unknown";
          leadsBySource[s] = (leadsBySource[s] ?? 0) + 1;
        }

        const totalAppts = appts.length;
        const apptsByStatus: Record<string, number> = {};
        for (const a of appts) {
          const s = a.status ?? "Unknown";
          apptsByStatus[s] = (apptsByStatus[s] ?? 0) + 1;
        }

        const totalConvos = convos.length;
        const openConvos = convos.filter((c: any) => c.status === "open").length;
        const smsConvos = convos.filter((c: any) => c.channel === "sms").length;

        const openDealsCount = deals.length;
        const pipelineValue = deals.reduce((sum: number, d: any) => sum + (Number(d.value) || 0), 0);

        const now = new Date();
        const openTasksCount = tasks.filter((t: any) => t.status !== "done").length;
        const overdueTasksCount = tasks.filter((t: any) => {
          if (t.status === "done") return false;
          if (!t.due_date) return false;
          return new Date(t.due_date) < now;
        }).length;

        // ── 4. Call GPT-4o-mini ─────────────────────
        const prompt = `You are a business analyst writing a brief weekly performance summary for a home service business owner.

Business: ${business.business_name ?? "this business"}
Period: Last 7 days

DATA:
- New leads: ${totalLeads}
- Leads converted to appointments: ${convertedLeads}
- Lead conversion rate: ${totalLeads > 0 ? Math.round((convertedLeads / totalLeads) * 100) : 0}%
- Lead statuses breakdown: ${JSON.stringify(leadsByStatus)}
- Lead sources breakdown: ${JSON.stringify(leadsBySource)}
- Total appointments this week: ${totalAppts}
- Appointment statuses: ${JSON.stringify(apptsByStatus)}
- New conversations: ${totalConvos} (${openConvos} still open, ${smsConvos} via SMS)
- Open pipeline: ${openDealsCount} open deals worth $${pipelineValue.toFixed(0)} total
- Tasks: ${openTasksCount} open, ${overdueTasksCount} currently overdue

Write a 3–4 sentence plain-text weekly insight summary. Be specific, use the actual numbers. Highlight what went well, flag anything that needs attention (e.g. low conversion, many open conversations, overdue tasks, or stalled pipeline value), and end with one actionable suggestion. No markdown, no bullet points, no headers. Write as if speaking directly to the business owner.`;

        const aiRes = await fetch("https://api.openai.com/v1/chat/completions", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model: "gpt-4o-mini",
            messages: [{ role: "user", content: prompt }],
            max_tokens: 200,
            temperature: 0.5,
          }),
        });

        const aiJson = await aiRes.json();
        if (!aiRes.ok) throw new Error(`OpenAI error: ${JSON.stringify(aiJson)}`);

        const summary = aiJson.choices?.[0]?.message?.content?.trim() ?? "";
        const promptTokens = aiJson.usage?.prompt_tokens ?? 0;
        const completionTokens = aiJson.usage?.completion_tokens ?? 0;
        const totalTokens = aiJson.usage?.total_tokens ?? 0;

        if (!summary) throw new Error("Empty summary from OpenAI");

        // ── 5. Write insight back to businesses row ────────────
        const { error: updateErr } = await supabase
          .from("businesses")
          .update({
            weekly_insight: {
              summary,
              stats: {
                new_leads: totalLeads,
                converted_leads: convertedLeads,
                total_appointments: totalAppts,
                new_conversations: totalConvos,
                open_deals: openDealsCount,
                pipeline_value: pipelineValue,
                overdue_tasks: overdueTasksCount,
              },
            },
            weekly_insight_generated_at: new Date().toISOString(),
            weekly_insight_status: "ok",
            weekly_insight_last_error: null,
          })
          .eq("id", businessId);

        if (updateErr) throw new Error(`Update businesses: ${updateErr.message}`);

        // ── 5b. Insert full audit-history row ──────────
        // businesses.weekly_insight above only keeps a trimmed stats object
        // for the dashboard card's fast read. This row keeps everything
        // that was actually fed to the prompt, for history/debugging.
        const { error: insightRowErr } = await supabase
          .from("dashboard_insights")
          .insert({
            business_id: businessId,
            summary,
            source_kpi_snapshot: {
              new_leads: totalLeads,
              converted_leads: convertedLeads,
              leads_by_status: leadsByStatus,
              leads_by_source: leadsBySource,
              total_appointments: totalAppts,
              appointments_by_status: apptsByStatus,
              new_conversations: totalConvos,
              open_conversations: openConvos,
              sms_conversations: smsConvos,
              open_deals: openDealsCount,
              pipeline_value: pipelineValue,
              open_tasks: openTasksCount,
              overdue_tasks: overdueTasksCount,
              prompt_tokens: promptTokens,
              completion_tokens: completionTokens,
              total_tokens: totalTokens,
              model: "gpt-4o-mini",
            },
            generated_at: new Date().toISOString(),
          });

        if (insightRowErr) {
          // Non-fatal — the dashboard card already reads from
          // businesses.weekly_insight above, which already succeeded.
          // Losing audit history shouldn't fail the whole run for this
          // business.
          console.error(`dashboard_insights insert failed for business ${businessId}: ${insightRowErr.message}`);
        }

        // ── 6. Log AI usage ───────────────────
        await supabase.from("ai_usage_logs").insert({
          business_id: businessId,
          action: "weekly_insight",
          minutes_used: 0,
          details: {
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: totalTokens,
            model: "gpt-4o-mini",
          },
        });

        console.log(`✓ Business ${businessId} (${business.business_name}): insight generated`);
        results.push({ business_id: businessId, status: "ok" });

      } catch (err: any) {
        console.error(`✗ Business ${business.id}: ${err.message}`);
        results.push({ business_id: business.id, status: "error", error: err.message });

        // Record the failure so the dashboard card can tell "never
        // generated yet" apart from "just tried and failed" — but
        // deliberately don't touch weekly_insight (keep showing the last
        // good summary) or weekly_insight_generated_at (don't cost the
        // business owner their next on-demand retry window over a
        // transient failure, e.g. an OpenAI hiccup).
        await supabase
          .from("businesses")
          .update({
            weekly_insight_status: "failed",
            weekly_insight_last_error: err.message,
            weekly_insight_failed_at: new Date().toISOString(),
          })
          .eq("id", business.id);
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err: any) {
    console.error("generate-weekly-insight fatal:", err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});