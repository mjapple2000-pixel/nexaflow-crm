// DEPRECATED — this was a temporary debug function used to diagnose the
// stripe-connect-webhook delivery gap on 2026-08-11. No longer needed.
// Safe to delete via Supabase Dashboard → Edge Functions.
Deno.serve(async () => {
  return new Response(JSON.stringify({ error: 'This debug function has been retired.' }), {
    status: 410,
    headers: { 'Content-Type': 'application/json' },
  })
})