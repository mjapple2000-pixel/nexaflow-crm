import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const BUCKET = "job-form-media";

function htmlResponse(message: string, status: number) {
  return new Response(
    `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Job Form PDF</title></head>
     <body style="font-family: sans-serif; padding: 40px; text-align: center; color: #333;">
       <p>${message}</p>
     </body></html>`,
    { status, headers: { ...corsHeaders, "Content-Type": "text/html" } }
  );
}

// A permanent, never-expiring link — the token itself never changes, but
// Supabase signed URLs always expire, so this endpoint mints a FRESH
// short-lived signed URL on every click and redirects to it. The lead can
// bookmark or reopen this link months later and it will always work,
// even though the underlying signed URL from any prior click is long dead.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const token = url.searchParams.get("token");

  if (!token) {
    return htmlResponse("This link is missing required information.", 400);
  }

  const { data: submission, error } = await supabase
    .from("job_form_submissions")
    .select("id, pdf_url")
    .eq("view_token", token)
    .is("deleted_at", null)
    .maybeSingle();

  if (error || !submission) {
    return htmlResponse("This link is no longer valid.", 404);
  }

  if (!submission.pdf_url) {
    return htmlResponse("This form's PDF is not ready yet. Please check back shortly or contact the business directly.", 404);
  }

  const { data: signed, error: signError } = await supabase.storage
    .from(BUCKET)
    .createSignedUrl(submission.pdf_url, 3600);

  if (signError || !signed?.signedUrl) {
    return htmlResponse("This document could not be loaded right now. Please try again later.", 500);
  }

  return new Response(null, {
    status: 302,
    headers: { ...corsHeaders, Location: signed.signedUrl },
  });
});