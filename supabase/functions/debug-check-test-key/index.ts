// DEPRECATED — temporary function used to confirm STRIPE_SECRET_KEY_TEST
// saved correctly on 2026-08-11. No longer needed.
// Safe to delete via Supabase Dashboard → Edge Functions.
Deno.serve(async () => {
  return new Response(JSON.stringify({ error: 'This debug function has been retired.' }), {
    status: 410,
    headers: { 'Content-Type': 'application/json' },
  })
})