import { createClient } from 'npm:@supabase/supabase-js@2'

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? ''
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08 ?? '',
)

Deno.serve(async (req) => {
  try {
    const period = new Date()
    period.setUTCDate(1)
    const periodStart = period.toISOString().slice(0, 10)

    const { data: rows, error } = await supabase
      .from('business_usage_live')
      .select('id, business_id, ai_messages_used, ai_messages_included, overage_units_reported, client_id')
      .eq('period_start', periodStart)
      .gt('ai_messages_used', 0)

    if (error) throw error

    let reported = 0
    const errors: string[] = []

    for (const row of rows ?? []) {
      const overageTotal = Math.max(0, row.ai_messages_used - row.ai_messages_included)
      const delta = overageTotal - row.overage_units_reported
      if (delta <= 0) continue

      const stripeCustomerId = (row as any).businesses?.client_id
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
          event_name: 'ai_message_overage',
          'payload[stripe_customer_id]': stripeCustomerId,
          'payload[value]': String(delta),
          identifier: `overage-${row.business_id}-${periodStart}-${overageTotal}`,
        }),
      })

      if (!res.ok) {
        errors.push(`business ${row.business_id}: ${await res.text()}`)
        continue
      }

      await supabase
        .from('business_usage')
        .update({ overage_units_reported: overageTotal })
        .eq('id', row.id)

      reported++
    }

    await supabase.from('cron_run_log').insert({
      function_name: 'report-ai-overage',
      success: errors.length === 0,
      detail: { reported, errors },
    })

    return new Response(JSON.stringify({ reported, errors }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    console.error('report-ai-overage fatal:', err)
    return new Response(JSON.stringify({ error: err.message }), { status: 500 })
  }
})