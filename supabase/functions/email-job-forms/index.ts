import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").nexaflow_service_role_2026_08
);

const SITE_BASE = "https://nexaflow-crm.web.app";
const FN_BASE = "https://rllriopqojaraceytdno.supabase.co/functions/v1";

function randomToken(): string {
  return crypto.randomUUID();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Not authenticated." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const { data: userData, error: userError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Not authenticated." }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const submissionIds: number[] = Array.isArray(body.submission_ids) ? body.submission_ids : [];
    const includePdf: boolean = body.include_pdf === true;
    const includeViewLink: boolean = body.include_view_link === true;
    // Optional manual override — if the office user edited the destination
    // address in the send dialog, this is used for every group instead of
    // each lead's own leads.lead_email. Auto-grouping by lead still happens
    // either way, since it drives which forms end up in which email body.
    const overrideEmail: string | null = body.override_email ?? null;

    if (submissionIds.length === 0 || (!includePdf && !includeViewLink)) {
      return new Response(
        JSON.stringify({ error: "submission_ids and at least one of include_pdf/include_view_link are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // ── Resolve business_id server-side from the caller's own profile,
    // never trusted from the client — matches get-job-form-data and
    // submit-job-form-action's pattern. Superuser fallback still needs
    // body.business_id since a superuser has no profiles row by design.
    let businessId: number;
    const { data: sessionProfile } = await supabase
      .from("profiles")
      .select("business_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();

    if (sessionProfile?.business_id) {
      businessId = sessionProfile.business_id;
    } else {
      const { data: superuser } = await supabase
        .from("superusers")
        .select("user_id")
        .eq("user_id", userData.user.id)
        .maybeSingle();
      if (superuser && body.business_id) {
        businessId = body.business_id;
      } else {
        return new Response(JSON.stringify({ error: "Could not resolve business for this session." }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    const { data: businessRow } = await supabase
      .from("businesses")
      .select("name")
      .eq("id", businessId)
      .maybeSingle();
    const businessName = businessRow?.name ?? "your service provider";

    // ── 1. Load submissions + resolve each one's lead via its appointment ──
    const { data: submissions, error: subError } = await supabase
      .from("job_form_submissions")
      .select("id, business_id, job_form_id, appointment_id, status, pdf_url, view_token")
      .in("id", submissionIds)
      .eq("business_id", businessId)
      .eq("status", "completed")
      .is("deleted_at", null);

    if (subError) {
      return new Response(JSON.stringify({ error: "Error loading submissions: " + subError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!submissions || submissions.length === 0) {
      return new Response(JSON.stringify({ error: "No completed submissions found for the given IDs." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const skipped: { submission_id: number; reason: string }[] = [];
    const validSubmissions = submissions.filter((s) => {
      if (!s.appointment_id) {
        skipped.push({ submission_id: s.id, reason: "Not linked to an appointment/lead." });
        return false;
      }
      return true;
    });

    const appointmentIds = [...new Set(validSubmissions.map((s) => s.appointment_id))];
    const { data: appointments, error: apptError } = await supabase
      .from("appointments")
      .select("id, lead_id, appointment_type")
      .in("id", appointmentIds);

    if (apptError) {
      return new Response(JSON.stringify({ error: "Error loading appointments: " + apptError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const apptById = new Map((appointments ?? []).map((a) => [a.id, a]));

    // ── 2. Job form names, for the email body ─────────────────────
    const jobFormIds = [...new Set(validSubmissions.map((s) => s.job_form_id))];
    const { data: jobForms } = await supabase
      .from("job_forms")
      .select("id, name, photo_attachment_markers")
      .in("id", jobFormIds);
    const formNameById = new Map((jobForms ?? []).map((f) => [f.id, f.name]));
    // marker_id -> label, keyed by job_form_id, so a photo attachment's
    // marker_id (free text, not a FK) can be resolved back to a
    // human-readable label for the email — same shape as
    // photo_attachment_markers everywhere else in the job-forms family.
    const markerLabelByForm = new Map<number, Map<string, string>>();
    for (const f of jobForms ?? []) {
      const markers = Array.isArray(f.photo_attachment_markers) ? f.photo_attachment_markers : [];
      const labelMap = new Map<string, string>();
      for (const m of markers) {
        if (m?.id) labelMap.set(m.id, m.label ?? "Photo");
      }
      markerLabelByForm.set(f.id, labelMap);
    }

    // ── 3. Group valid submissions by lead_id ─────────────────────
    const groups = new Map<number, typeof validSubmissions>();
    for (const s of validSubmissions) {
      const appt = apptById.get(s.appointment_id);
      const leadId = appt?.lead_id ?? null;
      if (!leadId) {
        skipped.push({ submission_id: s.id, reason: "Appointment has no linked lead." });
        continue;
      }
      if (!groups.has(leadId)) groups.set(leadId, []);
      groups.get(leadId)!.push(s);
    }

    if (groups.size === 0) {
      return new Response(
        JSON.stringify({ error: "None of the selected forms are linked to a lead.", skipped }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const leadIds = [...groups.keys()];
    const { data: leads, error: leadError } = await supabase
      .from("leads")
      .select("id, lead_name, lead_email")
      .in("id", leadIds);

    if (leadError) {
      return new Response(JSON.stringify({ error: "Error loading leads: " + leadError.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const leadById = new Map((leads ?? []).map((l) => [l.id, l]));

    // ── 4. Per lead group: ensure pdf/view links exist, build + send email ──
    const results: { lead_id: number; sent: boolean; reason?: string }[] = [];

    for (const [leadId, group] of groups.entries()) {
      const lead = leadById.get(leadId);
      const destinationEmail = overrideEmail || lead?.lead_email;
      if (!destinationEmail) {
        results.push({ lead_id: leadId, sent: false, reason: "No email address on file for this lead." });
        continue;
      }

      const lines: string[] = [];
      for (const s of group) {
        const formName = formNameById.get(s.job_form_id) ?? "Job Form";
        const formLines: string[] = [`<strong>${formName}</strong>`];

        // Resolve once per submission and reuse for both links below —
        // calling ensureViewToken twice against the same stale s.view_token
        // generated two different tokens and only the second write ever
        // survived in the database, silently breaking whichever link was
        // built first.
        let resolvedToken: string | null = null;
        if (includePdf || includeViewLink) {
          resolvedToken = await ensureViewToken(s.id, s.view_token);
        }

        if (includePdf) {
          // Generate the PDF now if it doesn't exist yet — a permanent
          // per-submission link is only useful once there's something for
          // it to point at. This mirrors what the office "Generate PDF"
          // button already does, just triggered automatically here rather
          // than requiring the office user to have clicked it first.
          let pdfUrl = s.pdf_url;
          if (!pdfUrl) {
            const genRes = await fetch(`${FN_BASE}/generate-job-form-pdf`, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ submission_id: s.id }),
            });
            if (genRes.ok) {
              const genBody = await genRes.json();
              pdfUrl = genBody.path ?? null;
            }
          }
          if (pdfUrl) {
            formLines.push(`<a href="${FN_BASE}/get-job-form-pdf-link?token=${resolvedToken}">Download PDF</a>`);
          } else {
            formLines.push("(PDF could not be generated)");
          }
        }

        if (includeViewLink) {
          formLines.push(`<a href="${SITE_BASE}/form-view/${resolvedToken}">View Online</a>`);
        }

        const photosHtml = await buildMarkerPhotosHtml(s.id, s.job_form_id, markerLabelByForm);

        lines.push(formLines.join(" — ") + photosHtml);
      }

      const subject = group.length === 1
        ? `Your completed form from ${businessName}`
        : `Your ${group.length} completed forms from ${businessName}`;

      const bodyHtml = `
        <p>Hi ${lead?.lead_name ?? "there"},</p>
        <p>Here ${group.length === 1 ? "is your completed form" : "are your completed forms"} from ${businessName}:</p>
        <p>${lines.join("<br/><br/>")}</p>
      `;

      try {
        const sendRes = await fetch(`${FN_BASE}/send-email`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            business_id: businessId,
            lead_ids: [leadId],
            subject,
            body: bodyHtml,
            override_email: overrideEmail,
          }),
        });
        if (!sendRes.ok) {
          const errText = await sendRes.text();
          results.push({ lead_id: leadId, sent: false, reason: `send-email failed: ${errText}` });
          continue;
        }
        results.push({ lead_id: leadId, sent: true });
      } catch (e) {
        results.push({ lead_id: leadId, sent: false, reason: e instanceof Error ? e.message : String(e) });
      }
    }

    return new Response(JSON.stringify({ success: true, results, skipped }), {
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

// Lazily creates a submission's view_token the first time either link
// type is needed — most submissions won't have one yet since this is the
// first feature that uses it. Never regenerated once set, since the
// token is meant to be a permanent, reusable identifier for that
// submission's lead-facing links.
async function ensureViewToken(submissionId: number, existing: string | null): Promise<string> {
  if (existing) return existing;
  const token = randomToken();
  await supabase.from("job_form_submissions").update({ view_token: token }).eq("id", submissionId);
  return token;
}

// Builds an inline HTML block of every marker photo attached to a
// submission — thumbnail, captured timestamp, and a tappable Google
// Maps link per photo — so a client reading the email can see exactly
// where each photo was taken without opening the PDF or View Online
// link. GPS is best-effort at capture time and legitimately absent for
// some photos; those just render without a map link.
async function buildMarkerPhotosHtml(
  submissionId: number,
  jobFormId: number,
  markerLabelByForm: Map<number, Map<string, string>>
): Promise<string> {
  const { data: attachments } = await supabase
    .from("job_form_photo_attachments")
    .select("marker_id, storage_path, latitude, longitude, captured_at")
    .eq("submission_id", submissionId)
    .is("deleted_at", null);

  if (!attachments || attachments.length === 0) return "";

  const labelMap = markerLabelByForm.get(jobFormId) ?? new Map<string, string>();
  const rows: string[] = [];

  for (const a of attachments) {
    const { data: signed } = await supabase.storage
      .from("job-form-media")
      .createSignedUrl(a.storage_path, 60 * 60 * 24 * 7); // 7 days — long enough to read an email, short enough not to be a permanent public link
    const url = signed?.signedUrl;
    if (!url) continue;

    const label = labelMap.get(a.marker_id) ?? "Photo";
    const timeText = a.captured_at
      ? new Date(a.captured_at).toLocaleString("en-US", {
          month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
        })
      : null;
    const mapLink =
      a.latitude != null && a.longitude != null
        ? `<a href="https://www.google.com/maps?q=${a.latitude},${a.longitude}" style="color:#2563eb;text-decoration:underline;">${a.latitude.toFixed(5)}, ${a.longitude.toFixed(5)}</a>`
        : "";

    rows.push(`
      <table style="margin-top:8px;" cellpadding="0" cellspacing="0"><tr>
        <td style="padding-right:10px;"><a href="${url}"><img src="${url}" width="64" height="64" style="border-radius:6px;border:1px solid #e5e7eb;object-fit:cover;" /></a></td>
        <td style="font-size:12px;color:#6b7280;vertical-align:top;">
          <div style="font-weight:600;color:#374151;">${label}</div>
          ${timeText ? `<div>${timeText}</div>` : ""}
          ${mapLink ? `<div>${mapLink}</div>` : ""}
        </td>
      </tr></table>
    `);
  }

  return rows.length ? `<div style="margin-top:6px;">${rows.join("")}</div>` : "";
}