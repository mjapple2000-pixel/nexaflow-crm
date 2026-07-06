import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;

Deno.serve(async (_req) => {
  try {
    // ── 1. Fetch all eligible businesses (Growth, Pro, or beta) ──────────────
    const { data: businesses, error: bizErr } = await supabase
      .from("businesses")
      .select("id, business_name, timezone, plan, subscription_status, is_beta");

    if (bizErr) throw new Error(`Fetch businesses: ${bizErr.message}`);

    console.log(`generate-weekly-insight: fetched ${businesses?.length ?? 0} total businesses`);
    console.log(`generate-weekly-insight: sample row: ${JSON.stringify(businesses?.[0] ?? null)}`);

    const eligible = (businesses ?? []).filter((b: any) =>
      b.is_beta === true ||
      ((b.subscription_status === "active" || b.subscription_status === "trialing") &&
        (b.plan === "growth" || b.plan === "pro"))
    );

    console.log(`generate-weekly-insight: ${eligible.length} eligible businesses`);

    const weekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
    const results: Array<{ business_id: number; status: string; error?: string }> = [];

    for (const business of eligible) {
      try {
        const businessId = business.id as number;

        // ── 2. Pull 7-day data scoped to this business ──────────────────────

        const [leadsRes, apptsRes, convosRes] = await Promise.all([
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
        ]);

        const leads = leadsRes.data ?? [];
        const appts = apptsRes.data ?? [];
        const convos = convosRes.data ?? [];

        // ── 3. Build summary stats for the prompt ───────────────────────────
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

        // ── 4. Call GPT-4o-mini ─────────────────────────────────────────────
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

Write a 3–4 sentence plain-text weekly insight summary. Be specific, use the actual numbers. Highlight what went well, flag anything that needs attention (e.g. low conversion, many open conversations), and end with one actionable suggestion. No markdown, no bullet points, no headers. Write as if speaking directly to the business owner.`;

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

        // ── 5. Write insight back to businesses row ─────────────────────────
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
              },
            },
            weekly_insight_generated_at: new Date().toISOString(),
          })
          .eq("id", businessId);

        if (updateErr) throw new Error(`Update businesses: ${updateErr.message}`);

        // ── 6. Log AI usage ─────────────────────────────────────────────────
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
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      headers: { "Content-Type": "application/json" },
    });

  } catch (err: any) {
    console.error("generate-weekly-insight fatal:", err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});