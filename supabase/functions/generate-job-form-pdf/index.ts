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
const SOURCE_BUCKET = "job-form-ai-sources";
const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 50;
const TEXT_DARK = rgb(0.13, 0.13, 0.15);
const TEXT_SECONDARY = rgb(0.42, 0.42, 0.46);
const BORDER_LIGHT = rgb(0.85, 0.85, 0.88);

function hexToRgb(hex: string) {
  const clean = (hex || "#6366F1").replace("#", "");
  const val = parseInt(clean.length === 6 ? clean : "6366F1", 16);
  return rgb(((val >> 16) & 255) / 255, ((val >> 8) & 255) / 255, (val & 255) / 255);
}

function isLightColor(hex: string): boolean {
  const clean = (hex || "#6366F1").replace("#", "");
  const val = parseInt(clean.length === 6 ? clean : "6366F1", 16);
  const r = (val >> 16) & 255, g = (val >> 8) & 255, b = val & 255;
  return (0.299 * r + 0.587 * g + 0.114 * b) > 150;
}

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

const RECREATION_FONT_SIZE = 20;
const CHECK_MARK_SIZE = 12;

async function embedImageAuto(pdfDoc: any, bytes: Uint8Array) {
  const isPng = bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  return isPng ? await pdfDoc.embedPng(bytes) : await pdfDoc.embedJpg(bytes);
}

// Converts an editor box (0-100 percentage, top-left origin, matching the
// coordinate editor) into PDF points (bottom-left origin).
function boxToPdfPoint(box: any, imgW: number, imgH: number) {
  const xPt = (box.x / 100) * imgW;
  const boxHeightPt = (box.h / 100) * imgH;
  const yTopPt = (box.y / 100) * imgH;
  const yBaselinePt = imgH - yTopPt - boxHeightPt;
  const boxWidthPt = (box.w / 100) * imgW;
  return { xPt, yBaselinePt, boxWidthPt, boxHeightPt };
}

function fitFontSize(font: any, text: string, maxWidthPt: number, defaultSize: number): number {
  let size = defaultSize;
  while (size > 7 && font.widthOfTextAtSize(text, size) > maxWidthPt) {
    size -= 1;
  }
  return size;
}

async function generateVisualRecreationPdf(
  { submission, jobForm, submission_id, businessRow }: { submission: any; jobForm: any; submission_id: number; businessRow: any }
) {
  try {
    // Page numbers are computed from the actual rendered output, not the
    // original scan — a business may append pages later (extra custom
    // pages, combined forms), so numbering must reflect the real final
    // page count rather than anything baked into the source images.
    const pdfSettings = businessRow?.pdf_settings ?? {};
    const showPageNumbers = pdfSettings.show_page_numbers !== false;
    const fields: any[] = jobForm.fields ?? [];
    const answers = submission.answers ?? {};
    const backgroundPages: string[] = jobForm.background_pages ?? [];

    const pdfDoc = await PDFDocument.create();
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const boldFont = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

    // Group fields by their 1-indexed page number so each background page
    // only draws the answers that belong to it.
    const fieldsByPage = new Map<number, any[]>();
    for (const f of fields) {
      const pg = f.page ?? 1;
      if (!fieldsByPage.has(pg)) fieldsByPage.set(pg, []);
      fieldsByPage.get(pg)!.push(f);
    }

    let signatureImg: any = null;
    if (submission.signature_url && jobForm.signature_box) {
      try {
        const { data: sigData } = await supabase.storage.from(BUCKET).download(submission.signature_url);
        if (sigData) {
          signatureImg = await embedImageAuto(pdfDoc, new Uint8Array(await sigData.arrayBuffer()));
        }
      } catch (e) {
        console.error("Signature embed error:", e);
      }
    }

    for (let i = 0; i < backgroundPages.length; i++) {
      const pageNum = i + 1;
      const { data: imgBlob, error: dlErr } = await supabase.storage.from(BUCKET).download(backgroundPages[i]);
      if (dlErr || !imgBlob) {
        console.error(`Failed to load background page ${pageNum}:`, dlErr?.message);
        continue;
      }
      const imgBytes = new Uint8Array(await imgBlob.arrayBuffer());
      const embeddedImg = await embedImageAuto(pdfDoc, imgBytes);
      const { width: imgW, height: imgH } = embeddedImg.scale(1);

      const page = pdfDoc.addPage([imgW, imgH]);
      page.drawImage(embeddedImg, { x: 0, y: 0, width: imgW, height: imgH });

      const pageFields = fieldsByPage.get(pageNum) ?? [];
      for (const field of pageFields) {
        const type = field.type ?? "text";
        const raw = answers[field.id];

        if (type === "photo") {
          continue; // no natural placement on a fixed background page
        }

        if (type === "checkbox") {
          if (raw === true && field.box) {
            const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(field.box, imgW, imgH);
            page.drawText("X", {
              x: xPt + boxWidthPt / 2 - CHECK_MARK_SIZE * 0.3,
              y: yBaselinePt + boxHeightPt / 2 - CHECK_MARK_SIZE * 0.35,
              size: CHECK_MARK_SIZE,
              font: boldFont,
              color: rgb(0.8, 0, 0),
            });
          }
          continue;
        }

        if (type === "select") {
          const chosen = raw ? String(raw) : null;
          const optionBoxes: any[] = field.option_boxes ?? [];
          const match = chosen ? optionBoxes.find((o) => o.label === chosen) : null;
          if (match?.box) {
            const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(match.box, imgW, imgH);
            page.drawText("X", {
              x: xPt + boxWidthPt / 2 - CHECK_MARK_SIZE * 0.3,
              y: yBaselinePt + boxHeightPt / 2 - CHECK_MARK_SIZE * 0.35,
              size: CHECK_MARK_SIZE,
              font: boldFont,
              color: rgb(0.8, 0, 0),
            });
          }
          continue;
        }

        if (type === "signature") {
          continue; // signature is drawn separately below via jobForm.signature_box + submission.signature_url
        }

        // text
        if (field.box && raw !== null && raw !== undefined && raw !== "") {
          const text = String(raw);
          const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(field.box, imgW, imgH);
          // Mask any pre-filled sample value baked into the original
          // scanned image before stamping the real answer, so old data
          // doesn't show through underneath the new value.
          page.drawRectangle({
            x: xPt - 2,
            y: yBaselinePt - 2,
            width: boxWidthPt + 4,
            height: boxHeightPt + 4,
            color: rgb(1, 1, 1),
          });
          const size = fitFontSize(font, text, boxWidthPt, RECREATION_FONT_SIZE);
          page.drawText(text, { x: xPt, y: yBaselinePt, size, font, color: rgb(0.75, 0, 0) });
        }
      }

      if (signatureImg && jobForm.signature_box?.page === pageNum && jobForm.signature_box?.box) {
        const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(jobForm.signature_box.box, imgW, imgH);
        const scale = Math.min(boxWidthPt / signatureImg.width, boxHeightPt / signatureImg.height, 1) || (boxWidthPt / signatureImg.width);
        const drawW = signatureImg.width * scale;
        const drawH = signatureImg.height * scale;
        page.drawImage(signatureImg, { x: xPt, y: yBaselinePt, width: drawW, height: drawH });
      }
    }

    if (showPageNumbers) {
      const startNum = jobForm.page_number_start ?? 1;
      const allOutputPages = pdfDoc.getPages();
      const totalNum = jobForm.page_number_total_override ?? allOutputPages.length;
      allOutputPages.forEach((p: any, idx: number) => {
        p.drawText(`Page ${startNum + idx} of ${totalNum}`, {
          x: p.getWidth() - 100,
          y: 14,
          size: 8,
          font,
          color: rgb(0.42, 0.42, 0.46),
        });
      });
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

    // Signed here using the service-role client (bypasses RLS) so the
    // response can be opened directly — signing separately with an
    // unauthenticated client fails against this bucket's policies.
    const { data: signed } = await supabase.storage.from(BUCKET).createSignedUrl(pdfPath, 3600);

    return new Response(JSON.stringify({ success: true, path: pdfPath, url: signed?.signedUrl }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Recreation PDF error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
}

async function generatePreviewPdf(
  { business_id, draft_id, source_page_paths, fields }: { business_id: number; draft_id: number; source_page_paths: string[]; fields: any[] }
) {
  try {
    if (!business_id || !draft_id || !Array.isArray(source_page_paths)) {
      return new Response(JSON.stringify({ error: "business_id, draft_id, and source_page_paths are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const pdfDoc = await PDFDocument.create();
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    const boldFont = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

    const fieldsByPage = new Map<number, any[]>();
    for (const f of fields) {
      const pg = f.page ?? 1;
      if (!fieldsByPage.has(pg)) fieldsByPage.set(pg, []);
      fieldsByPage.get(pg)!.push(f);
    }

    for (let i = 0; i < source_page_paths.length; i++) {
      const pageNum = i + 1;
      const { data: imgBlob, error: dlErr } = await supabase.storage.from(SOURCE_BUCKET).download(source_page_paths[i]);
      if (dlErr || !imgBlob) {
        console.error(`Failed to load source page ${pageNum}:`, dlErr?.message);
        continue;
      }
      const imgBytes = new Uint8Array(await imgBlob.arrayBuffer());
      const embeddedImg = await embedImageAuto(pdfDoc, imgBytes);
      const { width: imgW, height: imgH } = embeddedImg.scale(1);

      const page = pdfDoc.addPage([imgW, imgH]);
      page.drawImage(embeddedImg, { x: 0, y: 0, width: imgW, height: imgH });

      const pageFields = fieldsByPage.get(pageNum) ?? [];
      for (const field of pageFields) {
        const type = field.type ?? "text";
        if (!field.show_prefilled) continue;

        if (type === "checkbox") {
          if (field.box) {
            const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(field.box, imgW, imgH);
            page.drawText("X", {
              x: xPt + boxWidthPt / 2 - CHECK_MARK_SIZE * 0.3,
              y: yBaselinePt + boxHeightPt / 2 - CHECK_MARK_SIZE * 0.35,
              size: CHECK_MARK_SIZE,
              font: boldFont,
              color: rgb(0.8, 0, 0),
            });
          }
          continue;
        }

        if (type === "select") {
          const optionBoxes: any[] = field.option_boxes ?? [];
          const match = field.prefilled_value ? optionBoxes.find((o: any) => o.label === field.prefilled_value) : null;
          if (match?.box) {
            const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(match.box, imgW, imgH);
            page.drawText("X", {
              x: xPt + boxWidthPt / 2 - CHECK_MARK_SIZE * 0.3,
              y: yBaselinePt + boxHeightPt / 2 - CHECK_MARK_SIZE * 0.35,
              size: CHECK_MARK_SIZE,
              font: boldFont,
              color: rgb(0.8, 0, 0),
            });
          }
          continue;
        }

        if (type === "signature") {
          continue; // no real signature image exists in preview mode — never stamp OCR junk text on the signature line
        }

        if (field.box && field.prefilled_value) {
          const text = String(field.prefilled_value);
          const { xPt, yBaselinePt, boxWidthPt, boxHeightPt } = boxToPdfPoint(field.box, imgW, imgH);
          page.drawRectangle({
            x: xPt - 2, y: yBaselinePt - 2, width: boxWidthPt + 4, height: boxHeightPt + 4, color: rgb(1, 1, 1),
          });
          const size = fitFontSize(font, text, boxWidthPt, RECREATION_FONT_SIZE);
          page.drawText(text, { x: xPt, y: yBaselinePt, size, font, color: rgb(0.75, 0, 0) });
        }
      }
    }

    const pdfBytes = await pdfDoc.save();
    const outPath = `${business_id}/${draft_id}/preview-${Date.now()}.pdf`;
    await supabase.storage.from(SOURCE_BUCKET).upload(outPath, pdfBytes, { contentType: "application/pdf", upsert: true });
    const { data: signed } = await supabase.storage.from(SOURCE_BUCKET).createSignedUrl(outPath, 3600);

    return new Response(JSON.stringify({ success: true, url: signed?.signedUrl }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Preview error: " + (err instanceof Error ? err.message : String(err)) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { submission_id, draft_id, business_id, source_page_paths, fields: previewFields } = body;

    // Two modes share this one function: a real completed submission
    // (submission_id, writes a permanent PDF) or a draft preview (draft_id,
    // stamps current in-editor field state onto the still-temporary source
    // images — nothing saved to job_forms or permanent storage).
    if (draft_id && !submission_id) {
      return await generatePreviewPdf({ business_id, draft_id, source_page_paths, fields: previewFields ?? [] });
    }

    if (!submission_id) {
      return new Response(JSON.stringify({ error: "submission_id or draft_id is required" }), {
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
      .select("name, fields, recreation_mode, background_pages, signature_box, page_number_start, page_number_total_override")
      .eq("id", submission.job_form_id)
      .maybeSingle();

    const { data: businessRow } = await supabase
      .from("businesses")
      .select("pdf_settings, company_logo_url, business_phone, business_email, company_website")
      .eq("id", submission.business_id)
      .maybeSingle();

    // Visual recreation forms use the AI Form Recreation background pages +
    // per-field coordinates instead of the standard generated layout. The
    // original document's own header/footer/logo are already baked into
    // the background image, so this branch only ever draws answer values
    // on top — nothing else — to stay visually faithful to the source.
    if (jobForm?.recreation_mode === "visual_recreation" && Array.isArray(jobForm?.background_pages) && jobForm.background_pages.length > 0) {
      return await generateVisualRecreationPdf({ submission, jobForm, submission_id, businessRow });
    }

    const pdfSettings = businessRow?.pdf_settings ?? {};
    const BRAND = hexToRgb(pdfSettings.brand_color ?? "#6366F1");
    const BRAND_TEXT = isLightColor(pdfSettings.brand_color ?? "#6366F1") ? rgb(0.1, 0.1, 0.1) : rgb(1, 1, 1);
    const ACCENT = hexToRgb(pdfSettings.accent_color ?? "#10B981");
    const showPageNumbers = pdfSettings.show_page_numbers !== false;
    const showGeneratedDate = pdfSettings.show_generated_date !== false;
    const footerText: string | null = pdfSettings.footer_text ?? null;
    const disclaimerText: string | null = pdfSettings.disclaimer_text ?? null;
    const headerLayout: string = pdfSettings.header_layout ?? "compact";
    const headerStyle: string = pdfSettings.header_style ?? "modern";
    const logoSize: string = pdfSettings.logo_size ?? "medium";
    const footerFontSize: string = pdfSettings.footer_font_size ?? "medium";
    const footerPtSize = footerFontSize === "small" ? 7 : footerFontSize === "large" ? 10 : 8;
    const showCompanyPhone = pdfSettings.show_company_phone !== false;
    const showCompanyEmail = pdfSettings.show_company_email !== false;
    const showCompanyWebsite = pdfSettings.show_company_website !== false;
    const logoPx = logoSize === "small" ? 32 : logoSize === "large" ? 56 : 44;

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

    const allPages: any[] = [];
    let page = pdfDoc.addPage([PAGE_W, PAGE_H]);
    allPages.push(page);
    let y = PAGE_H - MARGIN;
    const contentWidth = PAGE_W - MARGIN * 2;

    function newPageIfNeeded(neededHeight: number) {
      if (y - neededHeight < MARGIN + 24) {
        page = pdfDoc.addPage([PAGE_W, PAGE_H]);
        allPages.push(page);
        y = PAGE_H - MARGIN;
      }
    }

    // ── Header ──────────────────────────────────────────────────────────────
    const headerLine = [appointmentInfo?.appointment_type, appointmentInfo?.lead_name].filter(Boolean).join("  —  ");
    const contactParts: string[] = [];
    if (showCompanyPhone && businessRow?.business_phone) contactParts.push(businessRow.business_phone);
    if (showCompanyEmail && businessRow?.business_email) contactParts.push(businessRow.business_email);
    if (showCompanyWebsite && businessRow?.company_website) contactParts.push(businessRow.company_website);
    const contactLine = contactParts.join("  ·  ");

    const isBasic = headerLayout === "basic";
    const isClean = headerStyle === "clean";

    let logoImg: any = null;
    if (businessRow?.company_logo_url) {
      try {
        const logoRes = await fetch(businessRow.company_logo_url);
        if (logoRes.ok) {
          const logoBytes = new Uint8Array(await logoRes.arrayBuffer());
          const contentType = logoRes.headers.get("content-type") ?? "";
          logoImg = contentType.includes("png")
            ? await pdfDoc.embedPng(logoBytes)
            : await pdfDoc.embedJpg(logoBytes);
        }
      } catch (e) {
        console.error("Logo embed error:", e);
      }
    }

    const bandHeight = (isBasic ? 74 : 58) + (headerLine ? 18 : 0) + (appointmentInfo?.location ? 16 : 0) + (contactLine ? 14 : 0);

    if (isClean) {
      page.drawRectangle({ x: 0, y: PAGE_H - 4, width: PAGE_W, height: 4, color: BRAND });
    } else {
      page.drawRectangle({ x: 0, y: PAGE_H - bandHeight, width: PAGE_W, height: bandHeight, color: BRAND });
    }

    const titleColor = isClean ? BRAND : BRAND_TEXT;
    const subColor = isClean ? TEXT_SECONDARY : rgb(0.93, 0.93, 1);
    const locColor = isClean ? TEXT_SECONDARY : rgb(0.88, 0.88, 0.98);

    let headerY = PAGE_H - (isBasic ? 44 : 36);
    let textX = MARGIN;

    if (logoImg) {
      const logoScale = logoPx / logoImg.height;
      const logoW = logoImg.width * logoScale;
      page.drawImage(logoImg, { x: MARGIN, y: headerY - logoPx + 8, width: logoW, height: logoPx });
      textX = MARGIN + logoW + 14;
    }

    page.drawText(jobForm?.name ?? "Job Form", { x: textX, y: headerY, size: isBasic ? 22 : 19, font: boldFont, color: titleColor });
    headerY -= isBasic ? 26 : 22;
    if (headerLine) {
      page.drawText(headerLine, { x: textX, y: headerY, size: 11, font, color: subColor });
      headerY -= 16;
    }
    if (appointmentInfo?.location) {
      page.drawText(appointmentInfo.location, { x: textX, y: headerY, size: 10, font, color: locColor });
      headerY -= 16;
    }
    if (contactLine) {
      page.drawText(contactLine, { x: textX, y: headerY, size: 9, font, color: locColor });
      headerY -= 14;
    }

    if (isClean) {
      page.drawLine({ start: { x: MARGIN, y: PAGE_H - bandHeight }, end: { x: PAGE_W - MARGIN, y: PAGE_H - bandHeight }, thickness: 1, color: BORDER_LIGHT });
    }

    y = PAGE_H - bandHeight - 28;

    // ── Fields ──────────────────────────────────────────────────────────────
    for (const field of fields) {
      const label = (field.label ?? "").toUpperCase();
      const type = field.type ?? "text";
      const raw = answers[field.id];

      newPageIfNeeded(60);
      page.drawRectangle({ x: MARGIN - 10, y: y - 4, width: 3, height: 14, color: ACCENT });
      page.drawText(label, { x: MARGIN, y, size: 10, font: boldFont, color: ACCENT });
      y -= 18;

      if (type === "checkbox") {
        const value = raw === true ? "Yes" : "No";
        page.drawText(value, { x: MARGIN, y, size: 12, font, color: TEXT_DARK });
        y -= 20;
      } else if (type === "photo") {
        const paths: string[] = Array.isArray(raw) ? raw : [];
        if (paths.length === 0) {
          page.drawText("No photos", { x: MARGIN, y, size: 10, font, color: TEXT_SECONDARY });
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
              newPageIfNeeded(drawH + 14);
              page.drawRectangle({
                x: MARGIN - 4, y: y - drawH - 4, width: drawW + 8, height: drawH + 8,
                borderColor: BORDER_LIGHT, borderWidth: 1, color: rgb(1, 1, 1),
              });
              page.drawImage(img, { x: MARGIN, y: y - drawH, width: drawW, height: drawH });
              y -= drawH + 14;
            } catch (e) {
              console.error("Photo embed error for", path, e);
            }
          }
        }
      } else {
        const text = raw === null || raw === undefined || raw === "" ? "—" : String(raw);
        const lines = wrapText(text, font, 12, contentWidth);
        for (const line of lines) {
          newPageIfNeeded(16);
          page.drawText(line, { x: MARGIN, y, size: 12, font, color: TEXT_DARK });
          y -= 16;
        }
        y -= 4;
      }
      y -= 6;
      page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_W - MARGIN, y }, thickness: 0.5, color: BORDER_LIGHT });
      y -= 14;
    }

    // ── Signature ───────────────────────────────────────────────────────────
    if (submission.signature_url) {
      newPageIfNeeded(160);
      y -= 10;
      page.drawRectangle({ x: MARGIN - 10, y: y - 4, width: 3, height: 14, color: ACCENT });
      page.drawText("SIGNATURE", { x: MARGIN, y, size: 10, font: boldFont, color: ACCENT });
      y -= 20;
      try {
        const { data: sigData } = await supabase.storage.from(BUCKET).download(submission.signature_url);
        if (sigData) {
          const bytes = new Uint8Array(await sigData.arrayBuffer());
          const img = await pdfDoc.embedPng(bytes);
          const maxW = 200;
          const scale = maxW / img.width;
          const drawH = img.height * scale;
          page.drawRectangle({
            x: MARGIN - 4, y: y - drawH - 4, width: maxW + 8, height: drawH + 8,
            borderColor: BORDER_LIGHT, borderWidth: 1, color: rgb(1, 1, 1),
          });
          page.drawImage(img, { x: MARGIN, y: y - drawH, width: maxW, height: drawH });
          y -= drawH + 14;
        }
      } catch (e) {
        console.error("Signature embed error:", e);
      }
      const signedLine = `Signed by ${submission.signed_by_name ?? "Unknown"} · ${submission.signed_at ? new Date(submission.signed_at).toLocaleString() : ""}`;
      page.drawText(signedLine, { x: MARGIN, y, size: 10, font, color: TEXT_SECONDARY });
      y -= 16;
    }

    if (disclaimerText) {
      newPageIfNeeded(60);
      y -= 6;
      page.drawRectangle({
        x: MARGIN, y: y - 40, width: contentWidth, height: 44,
        borderColor: BORDER_LIGHT, borderWidth: 1, color: rgb(0.98, 0.98, 0.99),
      });
      const disclaimerLines = wrapText(disclaimerText, font, 9, contentWidth - 20);
      let dy = y - 14;
      for (const line of disclaimerLines.slice(0, 3)) {
        page.drawText(line, { x: MARGIN + 10, y: dy, size: 9, font, color: TEXT_SECONDARY });
        dy -= 12;
      }
      y -= 50;
    }

    const generatedOn = new Date().toLocaleDateString();
    allPages.forEach((p: any, idx: number) => {
      p.drawLine({ start: { x: MARGIN, y: MARGIN - 10 }, end: { x: PAGE_W - MARGIN, y: MARGIN - 10 }, thickness: 0.5, color: BORDER_LIGHT });
      if (showGeneratedDate) {
        p.drawText(`Generated ${generatedOn}`, { x: MARGIN, y: MARGIN - 24, size: footerPtSize, font, color: TEXT_SECONDARY });
      }
      if (showPageNumbers) {
        p.drawText(`Page ${idx + 1} of ${allPages.length}`, { x: PAGE_W - MARGIN - 70, y: MARGIN - 24, size: footerPtSize, font, color: TEXT_SECONDARY });
      }
      if (footerText) {
        p.drawText(footerText, { x: MARGIN, y: MARGIN - 38, size: footerPtSize, font, color: TEXT_SECONDARY });
      }
    });

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