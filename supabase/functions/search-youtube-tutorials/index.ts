// search-youtube-tutorials
//
// Powers the "Watch & Learn" tab in the support bubble (lib/widgets/nexaflow_support_bubble.dart).
// Proxies a search to the YouTube Data API v3, scoped to ONE channel — the
// Nexaflow tutorials channel — so the client never sees the API key and can
// never search YouTube at large.
//
// Setup required before this works:
//   1. Add a secret named YOUTUBE_API_KEY (Supabase Dashboard → Edge Functions →
//      Secrets, or `supabase secrets set YOUTUBE_API_KEY=...`). Get a key from
//      Google Cloud Console → APIs & Services → Credentials, with the
//      "YouTube Data API v3" enabled on that project.
//   2. Create the cache table once in the SQL editor:
//
//        create table youtube_video_cache (
//          id bigint generated always as identity primary key,
//          query text not null,
//          results jsonb not null,
//          fetched_at timestamptz not null default now()
//        );
//        create unique index youtube_video_cache_query_idx on youtube_video_cache (query);
//
//      (No business_id — this is a single global channel shared by every
//      business, not per-tenant data, so normal RLS/business_id rules don't apply here.)
//
// The channel is resolved once by handle and cached in-memory for the life of
// the function instance — YOUTUBE_CHANNEL_HANDLE below is the only thing you
// should need to touch if the channel ever changes.

import { createClient } from "npm:@supabase/supabase-js@2";

const YOUTUBE_CHANNEL_HANDLE = "Marjoru-1"; // no leading @
const CACHE_TTL_MS = 6 * 60 * 60 * 1000; // 6 hours — tutorials don't change minute to minute

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  secretKeys.nexaflow_service_role_2026_08 ?? ""
);

let cachedChannelId: string | null = null;

async function resolveChannelId(apiKey: string): Promise<string> {
  if (cachedChannelId) return cachedChannelId;

  const url =
    `https://www.googleapis.com/youtube/v3/channels` +
    `?part=id&forHandle=${encodeURIComponent(YOUTUBE_CHANNEL_HANDLE)}&key=${apiKey}`;
  const res = await fetch(url);
  const data = await res.json();

  const id = data?.items?.[0]?.id;
  if (!id) {
    throw new Error(
      `Could not resolve channel handle "${YOUTUBE_CHANNEL_HANDLE}" — check the handle is correct and public.`
    );
  }
  cachedChannelId = id;
  return id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { query } = await req.json();
    const q = (query ?? "").toString().trim();

    const apiKey = Deno.env.get("YOUTUBE_API_KEY") ?? "";
    if (!apiKey) {
      return new Response(
        JSON.stringify({ error: "YOUTUBE_API_KEY is not configured on this project." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Cache key: empty query means "browse latest uploads", so give it its
    // own cache row distinct from a real search term.
    const cacheKey = q.length ? `search:${q.toLowerCase()}` : "browse:latest";

    // ── Check cache first ────────────────────────────────────────────────
    const { data: cached } = await supabase
      .from("youtube_video_cache")
      .select("results, fetched_at")
      .eq("query", cacheKey)
      .maybeSingle();

    if (cached && Date.now() - new Date(cached.fetched_at).getTime() < CACHE_TTL_MS) {
      return new Response(JSON.stringify({ videos: cached.results, cached: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ── Live fetch from YouTube ──────────────────────────────────────────
    const channelId = await resolveChannelId(apiKey);

    const searchUrl =
      `https://www.googleapis.com/youtube/v3/search` +
      `?part=snippet&channelId=${channelId}&type=video&order=${q.length ? "relevance" : "date"}` +
      `&maxResults=15&key=${apiKey}` +
      (q.length ? `&q=${encodeURIComponent(q)}` : "");

    const ytRes = await fetch(searchUrl);
    const ytData = await ytRes.json();

    if (!ytRes.ok) {
      console.error("YouTube API error:", JSON.stringify(ytData));
      return new Response(
        JSON.stringify({ error: ytData?.error?.message ?? "YouTube API request failed." }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const videos = (ytData.items ?? []).map((item: any) => ({
      video_id: item.id?.videoId,
      title: item.snippet?.title,
      thumbnail_url: item.snippet?.thumbnails?.medium?.url ?? item.snippet?.thumbnails?.default?.url,
      published_at: item.snippet?.publishedAt,
    })).filter((v: any) => v.video_id);

    // ── Write-through cache (best-effort; don't fail the request over it) ──
    await supabase
      .from("youtube_video_cache")
      .upsert({ query: cacheKey, results: videos, fetched_at: new Date().toISOString() }, { onConflict: "query" });

    return new Response(JSON.stringify({ videos, cached: false }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("search-youtube-tutorials error:", String(err));
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});