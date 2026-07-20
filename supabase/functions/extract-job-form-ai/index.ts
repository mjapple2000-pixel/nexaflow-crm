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
function centerInsideAnyRegion(
  box: { x: number; y: number; w: number; h: number },
  regions: Array<{ x: number; y: number; w: number; h: number }>,
): boolean {
  const cx = box.x + box.w / 2;
  const cy = box.y + box.h / 2;
  return regions.some((r) => cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h);
}

// A single-point-of-truth "is this the same text as that" is too strict
// when two Textract blocks (e.g. a KEY_VALUE_SET's own box vs. an
// independent LINE block covering the same words) don't share identical
// geometry — the center of one can legitimately fall just outside the
// other. Overlap area is more tolerant: if most of the candidate box
// covers a known region, it's the same text, regardless of exact bounds.
function overlapsAnyRegion(
  box: { x: number; y: number; w: number; h: number },
  regions: Array<{ x: number; y: number; w: number; h: number }>,
  minOverlapFraction = 0.5,
): boolean {
  const boxArea = box.w * box.h;
  if (boxArea <= 0) return false;
  return regions.some((r) => {
    const ix = Math.max(box.x, r.x);
    const iy = Math.max(box.y, r.y);
    const iw = Math.min(box.x + box.w, r.x + r.w) - ix;
    const ih = Math.min(box.y + box.h, r.y + r.h) - iy;
    if (iw <= 0 || ih <= 0) return false;
    return (iw * ih) / boxArea >= minOverlapFraction;
  });
}

function parseTextractBlocks(
  blocks: any[],
  page: number,
  itemsOut: Array<Record<string, unknown>>,
  idCounterRef: { n: number },
  tableRegions: Array<{ x: number; y: number; w: number; h: number }> = [],
) {
  const blockMap = new Map<string, any>();
  for (const b of blocks) blockMap.set(b.Id, b);

  // Textract detects a KEY's label text BOTH as part of the KEY_VALUE_SET
  // pair AND as its own independent LINE block covering the same words.
  // Without skipping the duplicate, every field label on the form produced
  // a guaranteed false "stray mark" — the real, correctly-matched
  // form_value item AND an orphaned duplicate of the same text.
  const keyBoxes: Array<{ x: number; y: number; w: number; h: number }> = [];
  const valueBoxes: Array<{ x: number; y: number; w: number; h: number }> = [];
  for (const block of blocks) {
    if (block.BlockType === 'KEY_VALUE_SET' && block.EntityTypes?.includes('KEY')) {
      const keyBox = toBoxPct(block.Geometry);
      if (keyBox) keyBoxes.push(keyBox);
      // The VALUE side (the actual answer text — "9/22/2025", a name, an
      // address) is ALSO independently detected as its own LINE block,
      // same as the KEY. That duplicate was still slipping through as a
      // false stray mark even after the KEY dedupe — every filled-in
      // answer field was throwing off one guaranteed duplicate.
      const valueRel = block.Relationships?.find((r: any) => r.Type === 'VALUE');
      if (valueRel) {
        for (const valueId of valueRel.Ids) {
          const valueBlock = blockMap.get(valueId);
          const valueBox = valueBlock ? toBoxPct(valueBlock.Geometry) : null;
          if (valueBox) valueBoxes.push(valueBox);
        }
      }
    }
  }

  for (const block of blocks) {
    if (block.BlockType === 'LINE') {
      const box = toBoxPct(block.Geometry);
      if (!box) continue;
      // Anything inside a detected table is already captured, with full
      // row/column context, by parseTableBlocks — including it again here
      // would hand GPT the same text twice: once gridded, once floating.
      if (centerInsideAnyRegion(box, tableRegions)) continue;
      if (overlapsAnyRegion(box, keyBoxes)) continue;
      if (overlapsAnyRegion(box, valueBoxes)) continue;
      itemsOut.push({ id: `ocr_${idCounterRef.n++}`, page, kind: 'line', text: block.Text ?? '', text_type: block.TextType ?? null, box });
    } else if (block.BlockType === 'SELECTION_ELEMENT') {
      const box = toBoxPct(block.Geometry);
      if (!box) continue;
      if (centerInsideAnyRegion(box, tableRegions)) continue;
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
        if (centerInsideAnyRegion(box, tableRegions)) continue;
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
): Array<{ x: number; y: number; w: number; h: number }> {
  const blockMap = new Map<string, any>();
  for (const b of blocks) blockMap.set(b.Id, b);

  const tableBlocks = blocks.filter((b) => b.BlockType === 'TABLE');
  const tableRegions: Array<{ x: number; y: number; w: number; h: number }> = [];
  let tableIndex = 0;

  for (const table of tableBlocks) {
    tableIndex++;
    const cellIds = (table.Relationships ?? [])
      .filter((r: any) => r.Type === 'CHILD')
      .flatMap((r: any) => r.Ids);
    const cells = cellIds
      .map((id: string) => blockMap.get(id))
      .filter((c: any) => c?.BlockType === 'CELL');

    const columnCount = cells.reduce((max: number, c: any) => Math.max(max, c.ColumnIndex ?? 0), 0);

    // Textract also table-detects simple 2-column label/value layout blocks
    // (Facility/Inspector/Door), which are already correctly captured once
    // by KEY_VALUE_SET parsing elsewhere. Generating deterministic row
    // fields for those too produced duplicate, garbage-labeled fields
    // ("Inspector (Table 2, Row 2)"). Real repeating checklist grids always
    // have 3+ columns — skip anything narrower and let it flow through the
    // normal, already-correct label/value path untouched.
    if (columnCount < 3) continue;

    const tableBox = toBoxPct(table.Geometry);
    if (tableBox) tableRegions.push(tableBox);

    const headerByCol = new Map<number, string>();
    for (const cell of cells) {
      if (cell.RowIndex === 1) {
        headerByCol.set(cell.ColumnIndex, getBlockText(cell, blockMap).trim());
      }
    }

    // Every data-row cell is emitted now, filled or empty, so the full grid
    // reaches GPT with row/column context. Previously filled cells were
    // skipped here and silently repicked-up as context-free LINE items
    // instead — that's what caused most Initials/Deficiencies misses: GPT
    // had no row/column to anchor a floating scrap of handwriting to.
    for (const cell of cells) {
      if (cell.RowIndex === 1) continue; // header row — already consumed above to label columns, not an answer cell itself

      // Some cells (e.g. "Signage complies with the following: [ ] Does
      // not exceed... [ ] Is attached...") contain real checkbox marks
      // mixed into their text. Lumping the whole cell into one giant text
      // field left every checkbox inside with no box of its own — only the
      // entire cell could be selected. Detect marks here and give each its
      // own TIGHT box, taken directly from the mark's own Textract
      // geometry — never widened or inferred from a neighboring cell/row,
      // which is what caused the earlier box-widening regression. This
      // stays entirely local to one cell's own children.
      const cellChildIds = (cell.Relationships ?? [])
        .filter((r: any) => r.Type === 'CHILD')
        .flatMap((r: any) => r.Ids);
      const cellChildren = cellChildIds.map((id: string) => blockMap.get(id)).filter(Boolean);
      const selectionChildren = cellChildren.filter((c: any) => c.BlockType === 'SELECTION_ELEMENT');

      if (selectionChildren.length > 0) {
        const wordChildren = cellChildren.filter((c: any) => c.BlockType === 'WORD');
        const avgWordHeight = wordChildren.length
          ? wordChildren.reduce((sum: number, w: any) => sum + (w.Geometry?.BoundingBox?.Height ?? 0), 0) / wordChildren.length
          : 0.02;

        for (const sel of selectionChildren) {
          const box = toBoxPct(sel.Geometry);
          if (!box) continue;
          const selTop = sel.Geometry?.BoundingBox?.Top ?? 0;
          const selMidY = selTop + (sel.Geometry?.BoundingBox?.Height ?? 0) / 2;
          // Words on roughly the same visual line as THIS specific checkbox
          // (within ~1.5 line-heights, matched only within this cell's own
          // words) become its label — e.g. "Does not exceed 5% of area".
          const nearbyWords = wordChildren
            .filter((w: any) => {
              const wTop = w.Geometry?.BoundingBox?.Top ?? 0;
              const wMidY = wTop + (w.Geometry?.BoundingBox?.Height ?? 0) / 2;
              return Math.abs(wMidY - selMidY) <= avgWordHeight * 1.5;
            })
            .sort((a: any, b: any) => (a.Geometry?.BoundingBox?.Left ?? 0) - (b.Geometry?.BoundingBox?.Left ?? 0))
            .map((w: any) => w.Text)
            .join(' ');

          itemsOut.push({
            id: `ocr_${idCounterRef.n++}`,
            page,
            kind: 'table_checkbox',
            table_index: tableIndex,
            column_header: headerByCol.get(cell.ColumnIndex) ?? null,
            row_index: cell.RowIndex,
            text: nearbyWords || headerByCol.get(cell.ColumnIndex) || 'Checkbox',
            selected: sel.SelectionStatus === 'SELECTED',
            box,
          });
        }
        // Checkbox marks are now individually captured above — do not also
        // emit the old whole-cell text blob, or the checkboxes would be
        // duplicated inside a big redundant text field.
        continue;
      }

      const text = getBlockText(cell, blockMap).trim();
      const box = toBoxPct(cell.Geometry);
      if (!box) continue;
      itemsOut.push({
        id: `ocr_${idCounterRef.n++}`,
        page,
        kind: 'table_cell',
        table_index: tableIndex,
        column_header: headerByCol.get(cell.ColumnIndex) ?? null,
        row_index: cell.RowIndex,
        text,
        box,
      });
    }
  }

  return tableRegions;
}

// Every table row/column comes straight from Textract's own grid — GPT
// previously collapsed a 7-row column into one field despite being told to
// enumerate rows, because a long repeating-structure instruction is exactly
// the kind of thing a model treats as optional. Building rows here instead
// guarantees one field per cell, every time, with zero model involvement.
function buildDeterministicTableFields(tableCellItems: Array<Record<string, unknown>>): any[] {
  return tableCellItems.map((item) => {
    const header = item.column_header ? String(item.column_header) : 'Field';
    const row = item.row_index as number;
    const tableIdx = item.table_index as number;

    // A checkbox mark detected inside a table cell — same shape as a
    // standalone checkbox elsewhere on the form (tight box, boolean state),
    // so it renders and behaves identically to page 1's checkboxes instead
    // of being lumped into one giant text field.
    if (item.kind === 'table_checkbox') {
      const label = (item.text as string) || header;
      const selected = item.selected === true;
      return {
        id: item.id,
        type: 'checkbox',
        label: `${label} (Table ${tableIdx}, Row ${row})`,
        section: null,
        required: false,
        is_filled_in: selected,
        detected_example_value: selected ? 'checked' : null,
        confidence: 1,
        page: item.page,
        box: item.box,
      };
    }

    const text = (item.text as string) ?? '';
    return {
      id: item.id, // temporary, renumbered below alongside GPT fields
      type: 'text',
      label: `${header} (Table ${tableIdx}, Row ${row})`,
      section: null,
      required: false,
      is_filled_in: text.trim().length > 0,
      detected_example_value: text.trim() ? text.trim() : null,
      confidence: text.trim() ? 1 : 0,
      page: item.page,
      box: item.box,
    };
  });
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
- "kind": "line" (a detected line of printed/handwritten text NOT inside any table), "checkbox" (a detected checkbox/selection mark, with "selected": true/false), or "form_value" (a detected label + its answer blank — "text" is the label, "value_text" is whatever was actually read inside the blank, which may be empty)
- "text" / "value_text": the text content, where applicable

IMPORTANT: table cells (rows/columns inside a detected table, e.g. an "Initials" or "Deficiencies" column that repeats down multiple rows) are NOT included in this OCR ITEMS list and are NOT your responsibility — a separate deterministic system already generates one field per table cell directly from measured grid data. Do not attempt to create fields for repeating table columns yourself; only handle standalone fields (labeled blanks, checkboxes, signatures, section headers) that appear in the list below.

CRITICAL DISTINCTION - do not confuse these two things:
1. The field's own LABEL/QUESTION TEXT — printed instructional or descriptive text that is part of the form's design itself (e.g. a checklist item description). This belongs in the "label" property. It is NEVER a filled-in answer, even though it may look like a long sentence.
2. An ANSWER someone actually wrote, checked, signed, or selected. Only this counts toward "is_filled_in" and "detected_example_value". Use the matching OCR item's "value_text" (for form_value items), "selected" status (for checkbox items), or "text" (for table_cell items) as your primary evidence — an empty "value_text", "selected": false, or empty "text" means NOT filled in, regardless of how descriptive the label text reads.

Set "is_filled_in": true and populate "detected_example_value" ONLY when a person has visibly entered, written, checked, or signed something into that specific field's blank. Otherwise set "is_filled_in": false and "detected_example_value": null.

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
    let rawPage2Bottom: any[] = []; // TEMPORARY DIAGNOSTIC

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
        const tableRegions = parseTableBlocks(blocks, pageNum, ocrItems, idCounter);
        parseTextractBlocks(blocks, pageNum, ocrItems, idCounter, tableRegions);
        // TEMPORARY DIAGNOSTIC — capture every raw block near the bottom
        // third of page 2 (BlockType + text + geometry + confidence),
        // regardless of type, so we can see whether Textract produced ANY
        // block for the circled "A" initials that our pipeline currently
        // never surfaces, versus it genuinely detecting nothing there.
        if (pageNum === 2) {
          rawPage2Bottom = blocks
            .filter((b: any) => (b.Geometry?.BoundingBox?.Top ?? 0) > 0.75)
            .map((b: any) => ({
              type: b.BlockType,
              text: b.Text ?? null,
              confidence: b.Confidence ?? null,
              box: toBoxPct(b.Geometry),
            }));
        }
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
    const tableCellItems = ocrItems.filter((item) => item.kind === 'table_cell' || item.kind === 'table_checkbox');
    const deterministicTableFields = buildDeterministicTableFields(tableCellItems);

    // Table cells AND table checkbox marks are excluded entirely from what
    // GPT sees — both are already handled deterministically above.
    const ocrItemsForPrompt = ocrItems
      .filter((item) => item.kind !== 'table_cell' && item.kind !== 'table_checkbox')
      .map(({ box: _box, label_box: _labelBox, ...rest }) => rest);

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
    const usedItemIds = new Set<string>();
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
          usedItemIds.add(field.source_item_id);
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
            usedItemIds.add(opt.item_id);
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
          usedItemIds.add(section.source_item_id);
          section.page = item.page;
          section.box = item.box;
        }
        delete section.source_item_id;
      }
    }
    extracted.sections = sectionsOut;

    // Merge GPT's non-table fields with the deterministic table fields,
    // then renumber everything in reading order (page, then top-to-bottom)
    // so ids stay sequential and sensible regardless of which source
    // produced which field.
    const allFields = [...fieldsOut, ...deterministicTableFields];
    allFields.sort((a: any, b: any) => {
      const pageDiff = (a.page ?? 1) - (b.page ?? 1);
      if (pageDiff !== 0) return pageDiff;
      return (a.box?.y ?? 0) - (b.box?.y ?? 0);
    });
    allFields.forEach((f: any, idx: number) => {
      f.id = `f_${String(idx + 1).padStart(3, '0')}`;
    });
    extracted.fields = allFields;

    // Anything Textract measured but GPT never assigned to a field or
    // section is either stray ink (a mark, a stamp, handwriting outside
    // any real field) or genuine OCR noise — either way it's something a
    // person may want to see and delete during cleanup. Only surface items
    // that actually contain something (non-empty text, a checked box, or
    // a filled-in value) — a blank, unused item isn't visible ink.
    const strayMarks = ocrItems
      .filter((item) => item.kind !== 'table_cell' && item.kind !== 'table_checkbox' && !usedItemIds.has(item.id as string))
      .filter((item) => {
        if (item.kind === 'line') {
          const text = (item.text as string)?.trim() ?? '';
          // TEMPORARY: not filtering by text_type here anymore — we don't
          // yet know if Textract's HANDWRITING/PRINTED classification
          // actually lines up with "added later" vs "original template
          // design" the way we assumed. Surfacing everything with real
          // content lets us see actual text_type values on the next test
          // run before writing a permanent rule.
          return !!text;
        }
        if (item.kind === 'checkbox') return item.selected === true;
        if (item.kind === 'form_value') return !!(item.value_text as string)?.trim();
        return false;
      })
      .map((item) => ({
        id: item.id,
        page: item.page,
        box: item.box,
        text: item.kind === 'form_value' ? item.value_text : item.text,
        text_type: item.text_type ?? null, // temporary diagnostic field — see if HANDWRITING/PRINTED classification is the real cause of missed stray marks
      }));
    extracted.stray_marks = strayMarks;

    // TEMPORARY DIAGNOSTIC — dumps every raw 'line' item Textract detected
    // on page 2, before any claiming/filtering/dedupe logic touches it.
    // This lets us see ground truth (does Textract even detect the "A"
    // initials as separate items? are they merged into the adjacent
    // sentence's LINE block? something else?) instead of guessing at a
    // filter rule. Remove this block once #2 (missing page 2 initials) is
    // diagnosed and fixed — it's not meant to ship long-term.
    extracted.debug_raw_lines_page2 = ocrItems
      .filter((item) => item.kind === 'line' && item.page === 2)
      .map((item) => ({ id: item.id, text: item.text, box: item.box }));
    extracted.debug_raw_blocks_page2_bottom = rawPage2Bottom;

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