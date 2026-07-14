import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')!;

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

const EXTRACTION_SYSTEM_PROMPT = `You are analyzing an image of a form (checklist, inspection form, or similar) used by a field service business. Identify every field on the form and return ONLY valid JSON, no markdown, no commentary, matching this exact shape:

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
      "page": integer - which image (1-indexed, in the order the images were provided) this field's answer box appears on,
      "box": { "x": number, "y": number, "w": number, "h": number } - the location of the blank/box where the ANSWER goes (not the label text) on that page, as PERCENTAGES of the full page width and height (0-100). x/y is the top-left corner of the box.
    }
  ]
}

For type "select" fields with multiple checkbox options on the form (e.g. three checkboxes for three choices), instead of a single "box", provide "option_boxes": an array of {"label": "string", "box": {x,y,w,h}} — one box per individual checkbox on the page, in the same percentage format. Omit "box" when using "option_boxes".

Coordinate accuracy matters — look carefully at where the actual blank, checkbox, or line is on the page, not where the printed label text is. The label and its answer box are usually in different locations (e.g. label on the left, blank on the right, or label above and blank below).

CRITICAL DISTINCTION - do not confuse these two things:
1. The field's own LABEL/QUESTION TEXT — this is printed instructional or descriptive text that is part of the form's design itself (e.g. a checklist item description like "Door and frame labels are present, clearly visible, and legible."). This text belongs in the "label" property. It is NEVER a filled-in answer, even though it looks like a long sentence.
2. An ANSWER someone actually wrote, checked, signed, or selected — this is handwriting, ink, a checkmark, a signature, a filled bubble, or typed data entered into a blank on the form. Only this counts toward "is_filled_in" and "detected_example_value".

Set "is_filled_in": true and populate "detected_example_value" ONLY when a person has visibly entered, written, checked, or signed something into that specific field's blank/box on the document. If a field's blank, box, or line is empty/unmarked, set "is_filled_in": false and "detected_example_value": null — even if the field's own label/question text is long or descriptive. Never treat the form's own printed question text as if it were a filled-in answer to itself.

If the form contains a repeating table (the same set of columns repeated for multiple rows, e.g. an inspection checklist with Initials/Item/Deficiency columns per row), extract each row as its own set of fields in sequence, grouped under the same "section" name for that table. Do not invent a repeating-group structure — flatten rows into individual fields in order.

Number field ids sequentially starting from f_001. If the same form spans multiple pages/images, continue the field numbering and section grouping across all pages as one continuous form.`;

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

    const imageContentBlocks = [];
    for (const path of pagePaths) {
      const { data: fileBlob, error: dlErr } = await supabase.storage
        .from('job-form-ai-sources')
        .download(path);
      if (dlErr || !fileBlob) continue;
      const arrayBuffer = await fileBlob.arrayBuffer();
      const base64 = uint8ToBase64(new Uint8Array(arrayBuffer));
      imageContentBlocks.push({
        type: 'image_url',
        image_url: { url: `data:image/png;base64,${base64}` },
      });
    }

    if (imageContentBlocks.length === 0) {
      await supabase.from('job_form_ai_drafts').update({
        status: 'error',
        error_message: 'Could not download any source pages',
      }).eq('id', draft_id);
      return jsonResponse({ error: 'Could not download source pages' }, 500);
    }

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
            content: [
              { type: 'text', text: 'Extract all fields from this form.' },
              ...imageContentBlocks,
            ],
          },
        ],
        response_format: { type: 'json_object' },
        max_tokens: 8000,
      }),
    });

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
      await supabase.from('job_form_ai_drafts').update({
        status: 'error',
        error_message: 'AI response was not valid JSON',
      }).eq('id', draft_id);
      return jsonResponse({ error: 'AI response was not valid JSON' }, 500);
    }

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