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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { job_form_id, page_index, box, test_text } = await req.json();

    if (!job_form_id || page_index === undefined || !box) {
      return new Response(JSON.stringify({ error: "job_form_id, page_index, and box are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: form, error: formError } = await supabase
      .from("job_forms")
      .select("background_pages")
      .eq("id", job_form_id)
      .single();

    if (formError || !form?.background_pages?.[page_index]) {
      return new Response(JSON.stringify({ error: "Could not find that background page." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const imagePath = form.background_pages[page_index];
    const { data: imageBlob, error: downloadError } = await supabase
      .storage
      .from("job-form-media")
      .download(imagePath);

    if (downloadError || !imageBlob) {
      return new Response(JSON.stringify({ error: `Failed to download background image: ${downloadError?.message}` }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const imageBytes = new Uint8Array(await imageBlob.arrayBuffer());

    // Detect real format from magic bytes rather than trusting the file
    // extension — pdfx on Flutter Web renders PDF pages as PNG regardless
    // of the requested format, so historical files named .jpg may actually
    // be PNGs. This makes the renderer correct either way.
    const isPng = imageBytes.length >= 8 &&
      imageBytes[0] === 0x89 && imageBytes[1] === 0x50 && imageBytes[2] === 0x4e && imageBytes[3] === 0x47;
    const isJpeg = imageBytes.length >= 2 && imageBytes[0] === 0xff && imageBytes[1] === 0xd8;

    if (!isPng && !isJpeg) {
      const firstBytesHex = Array.from(imageBytes.slice(0, 16))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join(" ");
      return new Response(JSON.stringify({
        error: "Downloaded file is neither a valid PNG nor JPEG.",
        image_path: imagePath,
        byte_length: imageBytes.length,
        first_16_bytes_hex: firstBytesHex,
      }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const pdfDoc = await PDFDocument.create();
    const embeddedImage = isPng ? await pdfDoc.embedPng(imageBytes) : await pdfDoc.embedJpg(imageBytes);
    const { width: imgW, height: imgH } = embeddedImage.scale(1);

    const page = pdfDoc.addPage([imgW, imgH]);
    page.drawImage(embeddedImage, { x: 0, y: 0, width: imgW, height: imgH });

    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const xPt = (box.x / 100) * imgW;
    const boxHeightPt = (box.h / 100) * imgH;
    const yTopPt = (box.y / 100) * imgH;
    const yBaselinePt = imgH - yTopPt - boxHeightPt;
    // Detected boxes are tightly cropped to existing text, not the full
    // cell/line height — deriving font size purely from box.h produces
    // text that's too small. A sane fixed default reads much closer to
    // the original form's own printed text size.
    const fontSize = 20;

    page.drawText(test_text ?? "TEST STAMP", {
      x: xPt,
      y: yBaselinePt,
      size: fontSize,
      font,
      color: rgb(1, 0, 0),
    });

    const pdfBytes = await pdfDoc.save();
    const outPath = `test-stamps/${job_form_id}-${Date.now()}.pdf`;
    await supabase.storage.from("job-form-media").upload(outPath, pdfBytes, {
      contentType: "application/pdf",
    });

    const { data: signed } = await supabase.storage
      .from("job-form-media")
      .createSignedUrl(outPath, 3600);

    return new Response(JSON.stringify({ success: true, url: signed?.signedUrl }), {
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