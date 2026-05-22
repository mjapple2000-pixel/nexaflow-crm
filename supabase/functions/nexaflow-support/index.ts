import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;

const NEXAFLOW_SYSTEM_PROMPT = `You are the NexaFlow Support Assistant — a friendly, knowledgeable helper built into the NexaFlow CRM platform.

NexaFlow is an AI-powered CRM that helps businesses manage leads, book appointments, run SMS/email campaigns, and automate follow-ups.

YOUR ROLE:
- Answer questions about how to use NexaFlow
- Help users navigate the platform
- Explain features clearly and concisely
- Troubleshoot common issues
- Guide users through workflows step by step

PLATFORM OVERVIEW:
- Dashboard: Overview of leads, deals, appointments, and revenue
- Contacts: Manage leads and customers, add tags, track status
- Pipelines: Kanban board for tracking deals through stages
- Appointments: Calendar with day/week/month views, booking management
- Conversations: Unified inbox for SMS and email conversations with leads
- Campaigns: Send bulk SMS or email campaigns to segmented audiences
- Automations: Trigger-based workflows (new lead → send SMS, etc.)
- AI Chat Widget: Embeddable chat widget for the business's own website
- Settings: Configure business profile, AI persona, availability, knowledge base

TONE:
- Warm, helpful, and concise
- Use short paragraphs — no walls of text
- Use numbered steps for instructions
- Never make up features that don't exist
- If unsure, say "I'm not sure about that — please contact NexaFlow support"

KNOWLEDGE BASE entries will be appended below when available.`;

Deno.serve(async (req) => {
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  try {
    const { message, business_id, user_id, chat_id, history } = await req.json();

    if (!message) {
      return new Response(JSON.stringify({ error: "Missing message" }), { status: 400 });
    }

    // ── Load NexaFlow KB ────────────────────────────────────────────────────
    const { data: kbEntries } = await supabase
      .from("nexaflow_kb")
      .select("category, title, content")
      .eq("is_active", true)
      .order("sort_order", { ascending: true });

    const kbText = (kbEntries ?? [])
      .map((e: any) => `[${e.category}] ${e.title}: ${e.content}`)
      .join("\n");

    const systemPrompt = kbText
      ? `${NEXAFLOW_SYSTEM_PROMPT}\n\nKNOWLEDGE BASE:\n${kbText}`
      : NEXAFLOW_SYSTEM_PROMPT;

    // ── Build messages ──────────────────────────────────────────────────────
    const messages = [
      { role: "system", content: systemPrompt },
      ...(history ?? []).slice(-12),
      { role: "user", content: message },
    ];

    // ── Call OpenAI ─────────────────────────────────────────────────────────
    const aiRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages,
        max_tokens: 500,
        temperature: 0.5,
      }),
    });

    const aiJson = await aiRes.json();
    if (!aiRes.ok) throw new Error(`OpenAI error: ${JSON.stringify(aiJson)}`);
    const reply = aiJson.choices?.[0]?.message?.content?.trim() ?? "Sorry, I couldn't generate a response.";

    // ── Log to support_chats ────────────────────────────────────────────────
    if (business_id || user_id) {
      const updatedHistory = [
        ...(history ?? []),
        { role: "user", content: message },
        { role: "assistant", content: reply },
      ].slice(-40); // keep last 40 messages

      if (chat_id) {
        // Update existing chat
        await supabase.from("support_chats").update({
          messages:     updatedHistory,
          last_message: message.slice(0, 200),
          updated_at:   new Date().toISOString(),
        }).eq("id", chat_id);
      } else {
        // Create new chat — return the id
        const { data: newChat } = await supabase.from("support_chats").insert({
          business_id:  business_id ?? null,
          user_id:      user_id ?? null,
          messages:     updatedHistory,
          last_message: message.slice(0, 200),
          updated_at:   new Date().toISOString(),
        }).select("id").maybeSingle();

        return new Response(
          JSON.stringify({ reply, chat_id: newChat?.id }),
          {
            headers: {
              "Content-Type": "application/json",
              "Access-Control-Allow-Origin": "*",
            },
          }
        );
      }
    }

    return new Response(
      JSON.stringify({ reply, chat_id: chat_id ?? null }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );

  } catch (err) {
    console.error("nexaflow-support error:", err);
    return new Response(
      JSON.stringify({ error: "Internal error", reply: "Sorry, something went wrong. Please try again." }),
      { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } }
    );
  }
});