import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const BUCKET = "job-form-media";
const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 50;

function wrapText(text: string, font: any, size: number, maxWidth: number): string[] {
  const words = text.split(" ");
  const lines: string[] = [];
  let current = "";
  for (const w of words) {
    const trial = current ? `${current} ${w}` : w;
    if (font.widthOfTextAtSize(trial, size) > maxWidth && current) {
      lines.push(current);
      current = w;
    } else {
      current = trial;
    }
  }
  if (current) lines.push(current);
  return lines;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { submission_id } = await req.json();
    if (!submission_id) {
      return new Response(JSON.stringify({ error: "submission_id is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: submission, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, business_id, job_form_id, appointment_id, answers, photo_urls, signature_url, signed_by_name, signed_at, status")
      .eq("id", submission_id)
      .maybeSingle();

    if (subError || !submission) {
      return new Response(JSON.stringify({ error: "Submission not found." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: jobForm } = await supabase
      .from("job_forms")
      .select("name, fields")
      .eq("id", submission.job_form_id)
      .maybeSingle();

    let appointmentInfo: any = null;
    if (submission.appointment_id) {
      const { data: appt } = await supabase
        .from("appointments")
        .select("appointment_type, lead_name, location")
        .eq("id", submission.appointment_id)
        .maybeSingle();
      appointmentInfo = appt ?? null;
    }

    const fields: any[] = jobForm?.fields ?? [];
    const answers = submission.answers ?? {};

    const pdfDoc = await PDFDocument.create();
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const boldFont = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

    let page = pdfDoc.addPage([PAGE_W, PAGE_H]);
    let y = PAGE_H - MARGIN;
    const contentWidth = PAGE_W - MARGIN * 2;

    function newPageIfNeeded(neededHeight: number) {
      if (y - neededHeight < MARGIN) {
        page = pdfDoc.addPage([PAGE_W, PAGE_H]);
        y = PAGE_H - MARGIN;
      }
    }

    // ── Header ──────────────────────────────────────────────────────────────
    page.drawText(jobForm?.name ?? "Job Form", { x: MARGIN, y, size: 20, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
    y -= 26;

    const headerLine = [appointmentInfo?.appointment_type, appointmentInfo?.lead_name].filter(Boolean).join("  —  ");
    if (headerLine) {
      page.drawText(headerLine, { x: MARGIN, y, size: 11, font, color: rgb(0.35, 0.35, 0.35) });
      y -= 16;
    }
    if (appointmentInfo?.location) {
      page.drawText(appointmentInfo.location, { x: MARGIN, y, size: 10, font, color: rgb(0.45, 0.45, 0.45) });
      y -= 16;
    }
    y -= 10;
    page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y }, thickness: 1, color: rgb(0.85, 0.85, 0.85) });
    y -= 24;

    // ── Fields ──────────────────────────────────────────────────────────────
    for (const field of fields) {
      const label = field.label ?? "";
      const type = field.type ?? "text";
      const raw = answers[field.id];

      newPageIfNeeded(60);
      page.drawText(label, { x: MARGIN, y, size: 11, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
      y -= 16;

      if (type === "checkbox") {
        const value = raw === true ? "Yes" : "No";
        page.drawText(value, { x: MARGIN, y, size: 11, font, color: rgb(0.2, 0.2, 0.2) });
        y -= 20;
      } else if (type === "photo") {
        const paths: string[] = Array.isArray(raw) ? raw : [];
        if (paths.length === 0) {
          page.drawText("No photos", { x: MARGIN, y, size: 10, font, color: rgb(0.55, 0.55, 0.55) });
          y -= 20;
        } else {
          for (const path of paths) {
            try {
              const { data: fileData } = await supabase.storage.from(BUCKET).download(path);
              if (!fileData) continue;
              const bytes = new Uint8Array(await fileData.arrayBuffer());
              const isPng = path.toLowerCase().endsWith(".png");
              const img = isPng ? await pdfDoc.embedPng(bytes) : await pdfDoc.embedJpg(bytes);
              const maxW = 200;
              const scale = maxW / img.width;
              const drawW = maxW;
              const drawH = img.height * scale;
              newPageIfNeeded(drawH + 10);
              page.drawImage(img, { x: MARGIN, y: y - drawH, width: drawW, height: drawH });
              y -= drawH + 10;
            } catch (e) {
              console.error("Photo embed error for", path, e);
            }
          }
        }
      } else {
        const text = raw === null || raw === undefined || raw === "" ? "—" : String(raw);
        const lines = wrapText(text, font, 11, contentWidth);
        for (const line of lines) {
          newPageIfNeeded(16);
          page.drawText(line, { x: MARGIN, y, size: 11, font, color: rgb(0.2, 0.2, 0.2) });
          y -= 16;
        }
        y -= 4;
      }
      y -= 8;
    }

    // ── Signature ───────────────────────────────────────────────────────────
    if (submission.signature_url) {
      newPageIfNeeded(140);
      page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y }, thickness: 1, color: rgb(0.85, 0.85, 0.85) });
      y -= 24;
      page.drawText("Signature", { x: MARGIN, y, size: 11, font: boldFont, color: rgb(0.1, 0.1, 0.1) });
      y -= 16;
      try {
        const { data: sigData } = await supabase.storage.from(BUCKET).download(submission.signature_url);
        if (sigData) {
          const bytes = new Uint8Array(await sigData.arrayBuffer());
          const img = await pdfDoc.embedPng(bytes);
          const maxW = 200;
          const scale = maxW / img.width;
          const drawH = img.height * scale;
          page.drawImage(img, { x: MARGIN, y: y - drawH, width: maxW, height: drawH });
          y -= drawH + 10;
        }
      } catch (e) {
        console.error("Signature embed error:", e);
      }
      const signedLine = `Signed by ${submission.signed_by_name ?? "Unknown"} · ${submission.signed_at ? new Date(submission.signed_at).toLocaleString() : ""}`;
      page.drawText(signedLine, { x: MARGIN, y, size: 10, font, color: rgb(0.4, 0.4, 0.4) });
      y -= 16;
    }

    const pdfBytes = await pdfDoc.save();
    const pdfPath = `${submission.business_id}/${submission_id}/completed-form.pdf`;

    const { error: uploadError } = await supabase.storage
      .from(BUCKET)
      .upload(pdfPath, pdfBytes, { contentType: "application/pdf", upsert: true });

    if (uploadError) {
      return new Response(JSON.stringify({ error: "PDF upload failed: " + uploadError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    await supabase.from("job_form_submissions").update({ pdf_url: pdfPath }).eq("id", submission_id);

    return new Response(JSON.stringify({ success: true, path: pdfPath }), {
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