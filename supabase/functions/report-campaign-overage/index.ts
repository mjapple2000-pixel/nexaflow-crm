import { createClient } from 'npm:@supabase/supabase-js@2'

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? ''
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08 ?? '',
)

Deno.serve(async (req) => {
  // Cron-secret check — report-ai-overage (this function's sibling) predates
  // this pattern and has none; adding it here since this endpoint reports
  // real billing events to Stripe and every other cron-triggered function
  // in this codebase checks it.
  const providedSecret = req.headers.get('x-cron-secret') ?? ''
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  try {
    const period = new Date()
    period.setUTCDate(1)
    const periodStart = period.toISOString().slice(0, 10)

    const { data: rows, error } = await supabase
      .from('business_usage_live')
      .select('id, business_id, campaign_sends_used, campaign_sends_included, campaign_overage_units_reported, client_id, is_beta, beta_card_added')
      .eq('period_start', periodStart)
      .or('is_beta.eq.false,beta_card_added.eq.true')
      .gt('campaign_sends_used', 0)

    if (error) throw error

    let reported = 0
    const errors: string[] = []

    for (const row of rows ?? []) {
      const overageTotal = Math.max(0, row.campaign_sends_used - row.campaign_sends_included)
      const delta = overageTotal - row.campaign_overage_units_reported
      if (delta <= 0) continue

      const stripeCustomerId = row.client_id
      if (!stripeCustomerId) {
        errors.push(`business ${row.business_id}: no Stripe client_id`)
        continue
      }

      const res = await fetch('https://api.stripe.com/v1/billing/meter_events', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          event_name: 'sms_campaign_send_overage',
          'payload[stripe_customer_id]': stripeCustomerId,
          'payload[value]': String(delta),
          identifier: `campaign-overage-${row.business_id}-${periodStart}-${overageTotal}`,
        }),
      })

      if (!res.ok) {
        errors.push(`business ${row.business_id}: ${await res.text()}`)
        continue
      }

      await supabase
        .from('business_usage')
        .update({ campaign_overage_units_reported: overageTotal })
        .eq('id', row.id)

      reported++
    }

    await supabase.from('cron_run_log').insert({
      function_name: 'report-campaign-overage',
      success: errors.length === 0,
      detail: { reported, errors },
    })

    return new Response(JSON.stringify({ reported, errors }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    console.error('report-campaign-overage fatal:', err)
    return new Response(JSON.stringify({ error: err.message }), { status: 500 })
  }
})