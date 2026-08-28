import { createClient } from 'npm:@supabase/supabase-js@2'

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? ''
const STRIPE_SEAT_OVERAGE_PRICE_ID = Deno.env.get('STRIPE_SEAT_OVERAGE_PRICE_ID') ?? ''
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08 ?? '',
)

Deno.serve(async (req) => {
  try {
    const cronSecret = req.headers.get('x-cron-secret')
    const authHeader = req.headers.get('Authorization')
    const expectedServiceKey = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}').nexaflow_service_role_2026_08 ?? ''
    const isAuthorized =
      cronSecret === '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93' ||
      authHeader === `Bearer ${expectedServiceKey}`

    if (!isAuthorized) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 })
    }
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {}
    const targetBusinessId = body.business_id ?? null

    let query = supabase
      .from('business_seats_live')
      .select('business_id, seats_used, seats_included, seat_overage_reported, stripe_seat_item_id, subscription_id, client_id, is_beta')
      .eq('is_beta', false)
      .not('subscription_id', 'is', null)

    if (targetBusinessId) {
      query = query.eq('business_id', targetBusinessId)
    }

    const { data: rows, error } = await query

    if (error) throw error

    let updated = 0
    const errors: string[] = []

    for (const row of rows ?? []) {
      const overage = Math.max(0, row.seats_used - row.seats_included)

      // No change since last sync — skip
      if (overage === row.seat_overage_reported) continue

      try {
        if (overage > 0 && row.stripe_seat_item_id) {
          // Existing line item — just update the quantity
          const res = await fetch(`https://api.stripe.com/v1/subscription_items/${row.stripe_seat_item_id}`, {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
              quantity: String(overage),
              proration_behavior: 'create_prorations',
            }),
          })
          if (!res.ok) throw new Error(await res.text())
        } else if (overage > 0 && !row.stripe_seat_item_id) {
          // First time this business has gone over — create the line item
          const res = await fetch('https://api.stripe.com/v1/subscription_items', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
              subscription: row.subscription_id,
              price: STRIPE_SEAT_OVERAGE_PRICE_ID,
              quantity: String(overage),
              proration_behavior: 'create_prorations',
            }),
          })
          if (!res.ok) throw new Error(await res.text())
          const item = await res.json()
          await supabase
            .from('businesses')
            .update({ stripe_seat_item_id: item.id })
            .eq('id', row.business_id)
        } else if (overage === 0 && row.stripe_seat_item_id) {
          // Back under the limit — remove the line item (Stripe doesn't allow qty 0)
          const res = await fetch(`https://api.stripe.com/v1/subscription_items/${row.stripe_seat_item_id}`, {
            method: 'DELETE',
            headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
          })
          if (!res.ok) throw new Error(await res.text())
          await supabase
            .from('businesses')
            .update({ stripe_seat_item_id: null })
            .eq('id', row.business_id)
        }

        await supabase
          .from('businesses')
          .update({ seat_overage_reported: overage })
          .eq('id', row.business_id)

        updated++
      } catch (err: any) {
        errors.push(`business ${row.business_id}: ${err.message}`)
      }
    }

    await supabase.from('cron_run_log').insert({
      function_name: 'sync-seat-overage',
      success: errors.length === 0,
      detail: { updated, errors },
    })

    return new Response(JSON.stringify({ updated, errors }), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    console.error('sync-seat-overage fatal:', err)
    return new Response(JSON.stringify({ error: err.message }), { status: 500 })
  }
})