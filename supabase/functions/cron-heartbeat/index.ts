import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? ''
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com'
const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''

const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}')

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  secretKeys.nexaflow_service_role_2026_08 ?? '',
)

// Runs weekly. Reads cron_run_log for daily-ticket-digest's activity in the
// trailing 7 days. daily-ticket-digest logs a row every time it runs —
// success or failure, email sent or suppressed — so a healthy week should
// show ~7 rows. If fewer than expected show up, the cron either stopped
// firing or is failing before it reaches the logging step, and this is the
// one email allowed to show up even when there's nothing else to report,
// because catching silent failure is its entire job.
//
// Table is deliberately generic (function_name column) so other cron jobs
// can log to it later — this check currently only watches daily-ticket-digest.

const WATCHED_FUNCTION = 'daily-ticket-digest'
const EXPECTED_RUNS_PER_WEEK = 7
const MIN_ACCEPTABLE_RUNS = 5 // some slack for late-night boundary runs

async function logRun(success: boolean, detail: Record<string, unknown>) {
  try {
    await supabase.from('cron_run_log').insert({
      function_name: 'cron-heartbeat',
      success,
      detail,
    })
  } catch (e) {
    console.error('Failed to write cron_run_log:', e)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const providedSecret = req.headers.get('x-cron-secret') ?? ''
    if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

    const { data: rows, error } = await supabase
      .from('cron_run_log')
      .select('id, ran_at, success')
      .eq('function_name', WATCHED_FUNCTION)
      .gte('ran_at', sevenDaysAgo)

    if (error) throw error

    const runCount = rows?.length ?? 0
    const failedCount = (rows ?? []).filter((r) => !r.success).length
    const healthy = runCount >= MIN_ACCEPTABLE_RUNS

    if (!healthy) {
      const form = new URLSearchParams()
      form.append('from', `VantageCareTech <no-reply@${MAILGUN_DOMAIN}>`)
      form.append('to', 'vantagecaretech@gmail.com')
      form.append('subject', `\u26a0\ufe0f Cron Heartbeat: ${WATCHED_FUNCTION} may not be running`)
      form.append(
        'text',
        `${WATCHED_FUNCTION} logged only ${runCount} run(s) in the last 7 days (expected around ${EXPECTED_RUNS_PER_WEEK}, minimum acceptable ${MIN_ACCEPTABLE_RUNS}).\n\n` +
          `${failedCount} of those logged runs failed.\n\n` +
          `This likely means the cron schedule isn't firing, or the function is erroring before it reaches its own logging step. Check the pg_cron job and function logs.`,
      )

      const mgRes = await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
        method: 'POST',
        headers: {
          'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.toString(),
      })

      if (!mgRes.ok) {
        const bodyText = await mgRes.text()
        throw new Error(`Mailgun error: ${bodyText}`)
      }
    }

    const resultPayload = { watched_function: WATCHED_FUNCTION, run_count: runCount, failed_count: failedCount, healthy, alert_sent: !healthy }
    await logRun(true, resultPayload)

    return new Response(JSON.stringify(resultPayload), {
      status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('cron-heartbeat error:', err)
    await logRun(false, { error: (err as Error).message })
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
