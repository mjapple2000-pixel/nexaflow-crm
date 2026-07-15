import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { TextractClient, AnalyzeDocumentCommand } from 'https://esm.sh/@aws-sdk/client-textract@3.658.1';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')!;

const textractClient = new TextractClient({
  region: Deno.env.get('AWS_REGION') ?? 'us-east-1',
  credentials: {
    accessKeyId: Deno.env.get('AWS_ACCESS_KEY_ID')!,
    secretAccessKey: Deno.env.get('AWS_SECRET_ACCESS_KEY')!,
  },
});

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function uint8ToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 8192;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

// Textract's BoundingBox is a 0-1 fraction of the page. Our fields/box
// contract (already locked in by the Flutter editor and PDF renderer) uses
// 0-100 percentages, so convert once here.
function toBoxPct(geometry: any): { x: number; y: number; w: number; h: number } | null {
  const bb = geometry?.BoundingBox;
  if (!bb) return null;
  return {
    x: Math.round(bb.Left * 1000) / 10,
    y: Math.round(bb.Top * 1000) / 10,
    w: Math.round(bb.Width * 1000) / 10,
    h: Math.round(bb.Height * 1000) / 10,
  };
}

function getBlockText(block: any, blockMap: Map<string, any>): string {
  if (!block.Relationships) return '';
  const childIds = block.Relationships.filter((r: any) => r.Type === 'CHILD').flatMap((r: any) => r.Ids);
  const words: string[] = [];
  for (const id of childIds) {
    const child = blockMap.get(id);
    if (child?.BlockType === 'WORD') words.push(child.Text);
    if (child?.BlockType === 'SELECTION_ELEMENT') words.push(child.SelectionStatus === 'SELECTED' ? '[X]' : '[ ]');
  }
  return words.join(' ');
}

// Flattens a Textract AnalyzeDocument response into a simple list of
// measured items (id, page, kind, text, box) that GPT will later reference
// by id — GPT never sees or produces raw coordinates itself.
function parseTextractBlocks(
  blocks: any[],
  page: number,
  itemsOut: Array<Record<string, unknown>>,
  idCounterRef: { n: number },
) {
  const blockMap = new Map<string, any>();
  for (const b of blocks) blockMap.set(b.Id, b);

  for (const block of blocks) {
    if (block.BlockType === 'LINE') {
      const box = toBoxPct(block.Geometry);
      if (!box) continue;
      itemsOut.push({ id: `ocr_${idCounterRef.n++}`, page, kind: 'line', text: block.Text ?? '', box });
    } else if (block.BlockType === 'SELECTION_ELEMENT') {
      const box = toBoxPct(block.Geometry);
      if (!box) continue;
      itemsOut.push({
        id: `ocr_${idCounterRef.n++}`,
        page,
        kind: 'checkbox',
        text: '',
        selected: block.SelectionStatus === 'SELECTED',
        box,
      });
    } else if (block.BlockType === 'KEY_VALUE_SET' && block.EntityTypes?.includes('KEY')) {
      const keyText = getBlockText(block, blockMap).trim();
      // The KEY block's own geometry is the label's position — previously
      // discarded entirely, so the label text had no location anywhere in
      // the pipeline and could never be shown as its own movable box.
      const keyBox = toBoxPct(block.Geometry);
      const valueRel = block.Relationships?.find((r: any) => r.Type === 'VALUE');
      if (!valueRel) continue;
      for (const valueId of valueRel.Ids) {
        const valueBlock = blockMap.get(valueId);
        if (!valueBlock) continue;
        const box = toBoxPct(valueBlock.Geometry);
        if (!box) continue;
        itemsOut.push({
          id: `ocr_${idCounterRef.n++}`,
          page,
          kind: 'form_value',
          text: keyText,
          value_text: getBlockText(valueBlock, blockMap).trim(),
          box,
          label_box: keyBox,
        });
      }
    }
  }
}

// LINE/SELECTION_ELEMENT/KEY_VALUE_SET parsing above only ever produces an
// item where Textract detected TEXT or a mark. A blank table cell (e.g. an
// unmarked Initials column) has neither — so it was previously invisible to
// GPT entirely, not mismatched, just missing. This walks Textract's TABLE/
// CELL structure and adds one item per EMPTY cell only (cells that already
// have text are covered above — no need to duplicate them). Each blank cell
// carries its column header as semantic context, since the cell itself has
// no text to describe what it's for.
function parseTableBlocks(
  blocks: any[],
  page: number,
  itemsOut: Array<Record<string, unknown>>,
  idCounterRef: { n: number },
) {
  const blockMap = new Map<string, any>();
  for (const b of blocks) blockMap.set(b.Id, b);

  const tableBlocks = blocks.filter((b) => b.BlockType === 'TABLE');

  for (const table of tableBlocks) {
    const cellIds = (table.Relationships ?? [])
      .filter((r: any) => r.Type === 'CHILD')
      .flatMap((r: any) => r.Ids);
    const cells = cellIds
      .map((id: string) => blockMap.get(id))
      .filter((c: any) => c?.BlockType === 'CELL');

    const headerByCol = new Map<number, string>();
    for (const cell of cells) {
      if (cell.RowIndex === 1) {
        headerByCol.set(cell.ColumnIndex, getBlockText(cell, blockMap).trim());
      }
    }

    for (const cell of cells) {
      if (cell.RowIndex === 1) continue; // header row itself isn't an answer cell
      const text = getBlockText(cell, blockMap).trim();
      if (text) continue; // has content — already captured by LINE parsing above
      const box = toBoxPct(cell.Geometry);
      if (!box) continue;
      itemsOut.push({
        id: `ocr_${idCounterRef.n++}`,
        page,
        kind: 'table_cell',
        column_header: headerByCol.get(cell.ColumnIndex) ?? null,
        row_index: cell.RowIndex,
        text: '',
        box,
      });
    }
  }
}

const EXTRACTION_SYSTEM_PROMPT = `You are analyzing a form (checklist, inspection form, or similar) used by a field service business. Identify every field on the form and return ONLY valid JSON, no markdown, no commentary, matching this exact shape:

{
  "fields": [
    {
      "id": "f_001",
      "type": "text" | "checkbox" | "select" | "photo" | "signature",
      "label": "string",
      "required": boolean,
      "options": ["string"] (only for type "select"),
      "section": "string or null - a logical grouping name if the form has visible sections/headers, otherwise null",
      "is_filled_in": boolean,
      "detected_example_value": "string or null",
      "confidence": number between 0 and 1,
      "page": integer - which image (1-indexed, in the order the images were provided) this field's answer appears on,
      "source_item_id": "string" - the id of the matching entry in the OCR ITEMS list below, marking where this field's ANSWER goes (the blank/checkbox/value area, not the label). Omit this property entirely if no OCR item corresponds to this field.
    }
  ],
  "sections": [
    {
      "title": "string - the section header's own text, exactly as printed (e.g. 'Facility', 'Inspector', 'Door', or the form's main title bar)",
      "source_item_id": "string - the id of the matching 'line' entry in the OCR ITEMS list for this exact header text"
    }
  ]
}

For type "select" fields with multiple checkbox options, instead of "source_item_id", provide "option_item_ids": an array of {"label": "string", "item_id": "string"} — one entry per checkbox option, using its matching id from the OCR ITEMS list.

Separately from fields, identify every visually distinct SECTION HEADER on the form — a heading or colored/bold bar that introduces a group of fields below it (e.g. "Facility", "Inspector", "Door", "Visual Inspection"), including the form's own main title if it's set apart as a heading. List each one once in "sections", referencing its own "line" item by id. Do not include field labels, instructional paragraphs, or table column headers as sections — only true group headings that visually separate one block of fields from the next.

You are also given an OCR ITEMS list below. Every item was measured directly from the document by a separate OCR system, so its position is exact and reliable. You do NOT have access to raw coordinates yourself — you must NEVER invent, estimate, or output your own x/y/w/h numbers. Your only job regarding position is to pick the correct "id" from the OCR ITEMS list for each field's answer location. Each OCR item has:
- "id": a stable identifier to reference
- "page": which page it's on
- "kind": "line" (a detected line of printed/handwritten text), "checkbox" (a detected checkbox/selection mark, with "selected": true/false), "form_value" (a detected label + its answer blank — "text" is the label, "value_text" is whatever was actually read inside the blank, which may be empty), or "table_cell" (a BLANK cell inside a detected table — it has no text of its own, since it's unmarked; "column_header" tells you which column it belongs to, e.g. "Initials", and "row_index" distinguishes which repeated row it's in)
- "text" / "value_text": the text content, where applicable
- For "table_cell" items specifically, use "column_header" as the basis for the field's label (e.g. an empty cell with column_header "Initials" in a repeating table row is an "Initials" field for that row), since the cell itself has no text to read

CRITICAL DISTINCTION - do not confuse these two things:
1. The field's own LABEL/QUESTION TEXT — printed instructional or descriptive text that is part of the form's design itself (e.g. a checklist item description). This belongs in the "label" property. It is NEVER a filled-in answer, even though it may look like a long sentence.
2. An ANSWER someone actually wrote, checked, signed, or selected. Only this counts toward "is_filled_in" and "detected_example_value". Use the matching OCR item's "value_text" (for form_value items) or "selected" status (for checkbox items) as your primary evidence — an empty "value_text" or "selected": false means NOT filled in, regardless of how descriptive the label text reads.

Set "is_filled_in": true and populate "detected_example_value" ONLY when a person has visibly entered, written, checked, or signed something into that specific field's blank. Otherwise set "is_filled_in": false and "detected_example_value": null.

If the form contains a repeating table (the same set of columns repeated for multiple rows), extract each row as its own set of fields in sequence, grouped under the same "section" name for that table. Flatten rows into individual fields in order — do not invent a repeating-group structure.

Number field ids sequentially starting from f_001. If the same form spans multiple pages/images, continue numbering and section grouping across all pages as one continuous form.`;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { draft_id, business_id: businessIdParam } = await req.json();
    if (!draft_id) {
      return jsonResponse({ error: 'draft_id is required' }, 400);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const authHeader = req.headers.get('Authorization') ?? '';
    const token = authHeader.replace('Bearer ', '');
    let resolvedBusinessId: number | null = null;

    if (token) {
      const { data: userData } = await supabase.auth.getUser(token);
      if (userData?.user) {
        const { data: profile } = await supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', userData.user.id)
          .maybeSingle();
        if (profile?.business_id) resolvedBusinessId = profile.business_id;
      }
    }
    if (!resolvedBusinessId && businessIdParam) {
      resolvedBusinessId = businessIdParam;
    }
    if (!resolvedBusinessId) {
      return jsonResponse({ error: 'Could not resolve business' }, 401);
    }

    const { data: draft, error: draftErr } = await supabase
      .from('job_form_ai_drafts')
      .select('*')
      .eq('id', draft_id)
      .eq('business_id', resolvedBusinessId)
      .maybeSingle();

    if (draftErr || !draft) {
      return jsonResponse({ error: 'Draft not found' }, 404);
    }

    const pagePaths: string[] = draft.source_page_urls ?? [];
    if (pagePaths.length === 0) {
      return jsonResponse({ error: 'No source pages on draft' }, 400);
    }

    const stageStart = Date.now();
    const ocrItems: Array<Record<string, unknown>> = [];
    const idCounter = { n: 1 };

    // Download + Textract each page CONCURRENTLY. Page images are
    // deliberately NOT sent to GPT anymore (see below) — we only need the
    // raw bytes here for Textract itself.
    const pageResults = await Promise.all(pagePaths.map(async (path, idx) => {
      const pageNum = idx + 1;
      const { data: fileBlob, error: dlErr } = await supabase.storage
        .from('job-form-ai-sources')
        .download(path);
      if (dlErr || !fileBlob) return { pageNum, ok: false };

      const arrayBuffer = await fileBlob.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer);

      // Textract gives real measured coordinates for this page. If it fails
      // on one page, don't fail the whole extraction — that page's fields
      // will just come back without a source_item_id and need manual
      // placement in the coordinate editor, same as before this change.
      try {
        const textractRes = await textractClient.send(new AnalyzeDocumentCommand({
          Document: { Bytes: bytes },
          FeatureTypes: ['FORMS', 'TABLES'],
        }));
        const blocks = textractRes.Blocks ?? [];
        parseTextractBlocks(blocks, pageNum, ocrItems, idCounter);
        parseTableBlocks(blocks, pageNum, ocrItems, idCounter);
      } catch (textractErr) {
        console.error(`Textract error on page ${pageNum}:`, textractErr);
      }

      return { pageNum, ok: true };
    }));

    console.log(`OCR phase took ${Date.now() - stageStart}ms for ${pagePaths.length} page(s)`);

    if (!pageResults.some((r) => r.ok)) {
      await supabase.from('job_form_ai_drafts').update({
        status: 'error',
        error_message: 'Could not download any source pages',
      }).eq('id', draft_id);
      return jsonResponse({ error: 'Could not download source pages' }, 500);
    }

    // GPT is no longer sent the page images at all. Textract already
    // extracted every piece of text with measured coordinates, so sending
    // full-resolution images on top of that was pure redundant cost and
    // latency — vision tokens are the slowest, heaviest part of any
    // multimodal call, and were very likely the real driver of the 80-150s
    // response times we were seeing, not output length alone. GPT's only
    // remaining job is semantic labeling of text it's already been given.
    const ocrItemsForPrompt = ocrItems.map(({ box: _box, label_box: _labelBox, ...rest }) => rest);

    const openaiStart = Date.now();
    const openaiRes = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          { role: 'system', content: EXTRACTION_SYSTEM_PROMPT },
          {
            role: 'user',
            content: `Extract all fields from this form using only the OCR items below (no page image is provided — rely entirely on this structured text).\n\nOCR ITEMS:\n${JSON.stringify(ocrItemsForPrompt)}`,
          },
        ],
        response_format: { type: 'json_object' },
        max_tokens: 8000,
      }),
    });
    console.log(`OpenAI call took ${Date.now() - openaiStart}ms`);

    if (!openaiRes.ok) {
      const errText = await openaiRes.text();
      await supabase.from('job_form_ai_drafts').update({
        status: 'error',
        error_message: `OpenAI error: ${errText.slice(0, 500)}`,
      }).eq('id', draft_id);
      return jsonResponse({ error: 'AI extraction failed' }, 500);
    }

    const openaiBody = await openaiRes.json();
    const rawContent = openaiBody.choices?.[0]?.message?.content ?? '{}';
    let extracted;
    try {
      extracted = JSON.parse(rawContent);
    } catch {
      const finishReason = openaiBody.choices?.[0]?.finish_reason ?? 'unknown';
      console.error(`JSON parse failed. finish_reason: ${finishReason}. Raw content (last 300 chars): ${rawContent.slice(-300)}`);
      await supabase.from('job_form_ai_drafts').update({
        status: 'error',
        error_message: `AI response was not valid JSON (finish_reason: ${finishReason}). Tail: ${rawContent.slice(-300)}`,
      }).eq('id', draft_id);
      return jsonResponse({ error: 'AI response was not valid JSON' }, 500);
    }

    // GPT only ever chose an id — swap it here for the real, Textract-measured
    // box. This is the step that guarantees coordinates are measured, not
    // guessed or transcribed by the model.
    const VALID_FIELD_TYPES = new Set(['text', 'checkbox', 'select', 'photo', 'signature']);
    const ocrById = new Map(ocrItems.map((item) => [item.id as string, item]));
    const fieldsOut = Array.isArray(extracted?.fields) ? extracted.fields : [];
    for (const field of fieldsOut) {
      // GPT is given two similarly-named vocabularies: the field "type" enum
      // (text/checkbox/select/photo/signature) and each OCR item's "kind"
      // (line/checkbox/form_value/table_cell). It occasionally echoes an OCR
      // kind value into a field's type by mistake (e.g. "form_value"), which
      // isn't a valid type and crashes the type dropdown on the client.
      // Never trust it — fall back to "text" if it's not a real type.
      if (!VALID_FIELD_TYPES.has(field.type)) {
        console.error(`Invalid field type "${field.type}" on field ${field.id}, defaulting to "text"`);
        field.type = 'text';
      }
      if (field.source_item_id) {
        const item = ocrById.get(field.source_item_id);
        if (item) {
          field.page = item.page;
          field.box = item.box;
          // GPT was instructed to label blank table cells using the column
          // header, but doesn't always follow that reliably — when it skips
          // it, the field previously reached the UI with no readable label
          // at all (surfacing as its raw internal id, e.g. "f_020"). This
          // guarantees a real label every time, regardless of what GPT did.
          if (item.kind === 'table_cell' && (!field.label || !field.label.trim())) {
            const header = item.column_header ? String(item.column_header) : 'Field';
            field.label = item.row_index ? `${header} (row ${item.row_index})` : header;
          }
          // Key-value pairs (e.g. "Facility Name" -> blank) had their
          // label's own measured position captured in Edit 1 above. Attach
          // it here automatically — GPT never has to choose or output this,
          // it's a direct passthrough of real Textract geometry.
          if (item.kind === 'form_value' && item.label_box) {
            field.label_box = item.label_box;
          }
        }
        delete field.source_item_id;
      }
      if (Array.isArray(field.option_item_ids)) {
        field.option_boxes = field.option_item_ids
          .map((opt: any) => {
            const item = ocrById.get(opt.item_id);
            if (!item) return null;
            if (!field.page) field.page = item.page;
            return { label: opt.label, box: item.box };
          })
          .filter((x: any) => x !== null);
        delete field.option_item_ids;
      }
    }

    // Resolve section headers the same way fields are resolved above — GPT
    // only ever chose an id, real geometry comes from Textract.
    const sectionsOut = Array.isArray(extracted?.sections) ? extracted.sections : [];
    for (const section of sectionsOut) {
      if (section.source_item_id) {
        const item = ocrById.get(section.source_item_id);
        if (item) {
          section.page = item.page;
          section.box = item.box;
        }
        delete section.source_item_id;
      }
    }
    extracted.sections = sectionsOut;

    await supabase.from('job_form_ai_drafts').update({
      status: 'ready_for_review',
      extracted_data: extracted,
      updated_at: new Date().toISOString(),
    }).eq('id', draft_id);

    return jsonResponse({ draft_id, status: 'ready_for_review', ...extracted });
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});