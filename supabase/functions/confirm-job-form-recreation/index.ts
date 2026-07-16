import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { business_id, draft_id, source_page_paths } = await req.json();

    if (!business_id || !draft_id || !Array.isArray(source_page_paths)) {
      return new Response(JSON.stringify({ error: "business_id, draft_id, and source_page_paths are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const permanentPaths: string[] = [];

    for (let i = 0; i < source_page_paths.length; i++) {
      const { data: fileBlob, error: downloadError } = await supabase
        .storage
        .from("job-form-ai-sources")
        .download(source_page_paths[i]);

      if (downloadError || !fileBlob) {
        return new Response(JSON.stringify({ error: `Failed to read source page ${i + 1}: ${downloadError?.message}` }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Keyed off the draft id, not a job_forms id — this runs BEFORE the
      // job_forms row exists, since a visual_recreation form must never be
      // created without its background images already secured.
      const destPath = `${business_id}/from-draft-${draft_id}/page-${i + 1}.png`;
      const bytes = new Uint8Array(await fileBlob.arrayBuffer());

      const { error: uploadError } = await supabase
        .storage
        .from("job-form-media")
        .upload(destPath, bytes, { contentType: "image/png", upsert: true });

      if (uploadError) {
        return new Response(JSON.stringify({ error: `Failed to save permanent page ${i + 1}: ${uploadError.message}` }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      permanentPaths.push(destPath);
    }

    return new Response(JSON.stringify({ success: true, background_pages: permanentPaths }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});