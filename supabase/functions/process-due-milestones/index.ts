import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  // Shared-secret check — this function is triggered by a scheduled
  // pg_cron job, not a logged-in user. Same pattern as
  // process-scheduled-automations: verify_jwt is false on this function,
  // so this header check is the only thing standing between the public
  // internet and a function that sends real SMS/email to customers.
  const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? '';
  const providedSecret = req.headers.get('x-cron-secret') ?? '';
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401, headers: { 'Content-Type': 'application/json' },
    });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const secretKeys  = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const serviceKey  = secretKeys.nexaflow_service_role_2026_08 ?? '';
    const db = createClient(supabaseUrl, serviceKey);

    const now = new Date().toISOString();

    // Pending milestones whose due_date has passed, on invoices that are
    // still live and actually progress-billed. Pulls the lead's phone/email
    // through the invoice's contact_id so we can pick a channel per Mike's
    // rule: SMS if the lead has a phone, email otherwise.
    const { data: dueMilestones, error: queryErr } = await db
      .from('invoice_milestones')
      .select(`
        id, label, invoice_id, business_id, due_date,
        invoices!inner (
          id, deleted_at, is_progress_billed, contact_id,
          leads ( lead_phone, lead_email )
        )
      `)
      .eq('status', 'pending')
      .lte('due_date', now)
      .is('deleted_at', null)
      .is('invoices.deleted_at', null)
      .eq('invoices.is_progress_billed', true);

    if (queryErr) throw queryErr;

    if (!dueMilestones || dueMilestones.length === 0) {
      return new Response(JSON.stringify({ processed: 0 }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }

    console.log(`Found ${dueMilestones.length} past-due milestone(s) to auto-trigger`);

    const results: Array<Record<string, unknown>> = [];

    for (const m of dueMilestones as any[]) {
      const invoice = m.invoices;
      const lead = invoice?.leads;
      const phone = lead?.lead_phone as string | undefined;
      const email = lead?.lead_email as string | undefined;

      // No contact info at all — nothing we can auto-send. Leave it
      // pending rather than silently marking ready_to_bill with no
      // notification sent; the business still needs to see this in
      // the invoice detail screen and send it manually.
      if (!phone && !email) {
        results.push({ milestone_id: m.id, status: 'skipped', reason: 'no phone or email on file' });
        continue;
      }

      const channel = phone ? 'sms' : 'email';

      // Flip to ready_to_bill first — send-milestone-invoice requires
      // this status before it will send, same gate the manual button uses.
      const { error: updateErr } = await db
        .from('invoice_milestones')
        .update({ status: 'ready_to_bill', updated_at: now })
        .eq('id', m.id);

      if (updateErr) {
        results.push({ milestone_id: m.id, status: 'error', error: updateErr.message });
        continue;
      }

      try {
        const sendRes = await fetch(`${supabaseUrl}/functions/v1/send-milestone-invoice`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${serviceKey}`,
          },
          body: JSON.stringify({
            milestone_id: m.id,
            invoice_id:   m.invoice_id,
            business_id:  m.business_id,
            channel,
          }),
        });

        const sendData = await sendRes.json();
        if (!sendRes.ok) {
          results.push({ milestone_id: m.id, status: 'send_failed', channel, error: sendData.error ?? 'unknown error' });
        } else {
          results.push({ milestone_id: m.id, status: 'sent', channel });
        }
      } catch (e) {
        results.push({ milestone_id: m.id, status: 'send_failed', channel, error: (e as Error).message });
      }
    }

    return new Response(JSON.stringify({ processed: results.length, results }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });

  } catch (e) {
    console.error('process-due-milestones error:', e);
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    });
  }
});