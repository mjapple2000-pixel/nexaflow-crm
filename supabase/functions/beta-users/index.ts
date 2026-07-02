const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // Fetch all beta businesses with their contact info
    const res = await fetch(
      `${supabaseUrl}/rest/v1/businesses?is_beta=eq.true&select=id,business_name,beta_first_name,beta_email,owner_email,owner_name`,
      {
        headers: {
          'apikey': serviceRoleKey,
          'Authorization': `Bearer ${serviceRoleKey}`,
        },
      }
    )

    const businesses = await res.json()

    // Build list of recipients
    const recipients = businesses
      .map((b: any) => ({
        first_name: b.beta_first_name || b.owner_name || 'there',
        email: b.beta_email || b.owner_email || null,
        business_name: b.business_name || 'your business',
      }))
      .filter((r: any) => r.email !== null)

    return new Response(
      JSON.stringify({ recipients, count: recipients.length }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (e) {
    return new Response(
      JSON.stringify({ error: e.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})