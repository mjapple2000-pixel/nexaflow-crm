import { createClient } from 'npm:@supabase/supabase-js@2';

const MAILGUN_API_KEY = Deno.env.get('MAILGUN_API_KEY') ?? '';
const MAILGUN_DOMAIN = Deno.env.get('MAILGUN_DOMAIN') ?? 'mail.vantagecaretech.com';

// How close to the threshold counts as "approaching" — 1 hour, matching
// the buffer Mike asked for. Not currently configurable per business.
const APPROACHING_BUFFER_MINUTES = 60;

const WEEKDAY_INDEX: Record<string, number> = {
  sunday: 0, monday: 1, tuesday: 2, wednesday: 3, thursday: 4, friday: 5, saturday: 6,
};

function weekStartKeyFor(dateOnly: string, weekStartIndex: number): string {
  const d = new Date(`${dateOnly}T00:00:00.000Z`);
  const dow = d.getUTCDay();
  const diff = (dow - weekStartIndex + 7) % 7;
  d.setUTCDate(d.getUTCDate() - diff);
  return d.toISOString().substring(0, 10);
}

function formatHours(minutes: number): string {
  return (minutes / 60).toFixed(1).replace(/\.0$/, '');
}

async function sendOvertimeEmail(params: {
  ownerEmail: string;
  businessName: string;
  employeeName: string;
  kind: 'daily_approaching' | 'daily_crossed' | 'weekly_approaching' | 'weekly_crossed';
  minutesLogged: number;
  thresholdMinutes: number;
}) {
  if (!MAILGUN_API_KEY || !params.ownerEmail) return;

  const isWeekly = params.kind.startsWith('weekly');
  const isCrossed = params.kind.endsWith('crossed');
  const period = isWeekly ? 'week' : 'day';
  const thresholdHours = formatHours(params.thresholdMinutes);
  const loggedHours = formatHours(params.minutesLogged);

  const subject = isCrossed
    ? `Overtime alert: ${params.employeeName} has crossed into ${period}ly overtime`
    : `Heads up: ${params.employeeName} is nearing ${period}ly overtime`;

  const bodyLine = isCrossed
    ? `<strong>${params.employeeName}</strong> has logged <strong>${loggedHours}h</strong> this ${period} at <strong>${params.businessName}</strong>, past the ${thresholdHours}h ${period}ly overtime threshold.`
    : `<strong>${params.employeeName}</strong> has logged <strong>${loggedHours}h</strong> this ${period} at <strong>${params.businessName}</strong>, within an hour of the ${thresholdHours}h ${period}ly overtime threshold.`;

  try {
    const mgForm = new URLSearchParams();
    mgForm.append('from', `${params.businessName} <no-reply@${MAILGUN_DOMAIN}>`);
    mgForm.append('to', params.ownerEmail);
    mgForm.append('subject', subject);
    mgForm.append('html', `<p>${bodyLine}</p><p>Check Timesheets in NexaFlow for the full breakdown.</p>`);

    await fetch(`https://api.mailgun.net/v3/${MAILGUN_DOMAIN}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + btoa(`api:${MAILGUN_API_KEY}`),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: mgForm.toString(),
    });
  } catch (mgErr) {
    console.error('Overtime notification Mailgun send error:', mgErr);
  }
}

Deno.serve(async (req) => {
  // Shared-secret check — triggered by pg_cron, not a logged-in user.
  // Same pattern as process-due-milestones: verify_jwt is false on this
  // function, so this header check is the only gate on the public internet.
  const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? '';
  const providedSecret = req.headers.get('x-cron-secret') ?? '';
  if (!CRON_SECRET || providedSecret !== CRON_SECRET) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401, headers: { 'Content-Type': 'application/json' },
    });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const serviceKey = secretKeys.nexaflow_service_role_2026_08 ?? '';
    const db = createClient(supabaseUrl, serviceKey);

    // Only businesses that could even pass check_plan_feature('overtime_tracking')
    // — Pro-plan-paid-active/trialing, or beta. Mirrors the SQL in check_plan_feature.
    const { data: businesses, error: bizErr } = await db
      .from('businesses')
      .select('id, business_name, owner_email, week_start_day, is_beta, plan, is_paid, subscription_status')
      .or('is_beta.eq.true,and(plan.eq.pro,is_paid.eq.true,subscription_status.in.(active,trialing))');

    if (bizErr) throw bizErr;
    if (!businesses || businesses.length === 0) {
      return new Response(JSON.stringify({ checked: 0, sent: 0 }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }

    const now = new Date();
    const todayStr = now.toISOString().substring(0, 10);
    let sentCount = 0;
    const results: Array<Record<string, unknown>> = [];

    for (const biz of businesses) {
      const { data: rules } = await db
        .from('overtime_rules')
        .select('daily_threshold_hours, daily_ot_enabled, weekly_threshold_hours, weekly_ot_enabled')
        .eq('business_id', biz.id)
        .is('deleted_at', null)
        .maybeSingle();

      if (!rules || (!rules.daily_ot_enabled && !rules.weekly_ot_enabled)) continue;
      if (!biz.owner_email) continue;

      const weekStartIndex = biz.week_start_day && WEEKDAY_INDEX[biz.week_start_day] !== undefined
        ? WEEKDAY_INDEX[biz.week_start_day]
        : 1;
      const weekStartStr = weekStartKeyFor(todayStr, weekStartIndex);

      const { data: profiles } = await db
        .from('profiles')
        .select('user_id, full_name')
        .eq('business_id', biz.id)
        .not('user_id', 'is', null);
      const nameByUserId: Record<string, string> = {};
      for (const p of (profiles ?? [])) {
        if (p.user_id) nameByUserId[p.user_id] = p.full_name ?? 'Unknown';
      }
      if (Object.keys(nameByUserId).length === 0) continue;

      // Last 8 days covers any 7-day week regardless of week_start_day.
      const rangeStart = new Date(now);
      rangeStart.setUTCDate(rangeStart.getUTCDate() - 7);
      const { data: entries } = await db
        .from('time_entries')
        .select('id, user_id, clocked_in_at, clocked_out_at, duration_minutes, status')
        .eq('business_id', biz.id)
        .is('deleted_at', null)
        .gte('clocked_in_at', rangeStart.toISOString());

      if (!entries || entries.length === 0) continue;

      const entryIds = entries.map((e) => e.id);
      const unpaidByEntryId: Record<number, number> = {};
      if (entryIds.length > 0) {
        const { data: breaks } = await db
          .from('time_entry_breaks')
          .select('time_entry_id, started_at, ended_at, is_paid')
          .in('time_entry_id', entryIds)
          .is('deleted_at', null)
          .not('ended_at', 'is', null);
        for (const b of (breaks ?? [])) {
          if (b.is_paid) continue;
          const mins = Math.round((new Date(b.ended_at).getTime() - new Date(b.started_at).getTime()) / 60000);
          unpaidByEntryId[b.time_entry_id] = (unpaidByEntryId[b.time_entry_id] ?? 0) + mins;
        }
      }

      const dayMinutesByUserDay: Record<string, number> = {};
      for (const e of entries) {
        const dateOnly = String(e.clocked_in_at).substring(0, 10);
        const unpaid = unpaidByEntryId[e.id] ?? 0;
        let minutes: number;
        if (e.status === 'active') {
          // Still clocked in right now — use elapsed time so far, so
          // "approaching" can fire before they've actually clocked out.
          minutes = Math.max(0, Math.round((now.getTime() - new Date(e.clocked_in_at).getTime()) / 60000) - unpaid);
        } else {
          minutes = Math.max(0, (e.duration_minutes ?? 0) - unpaid);
        }
        const key = `${e.user_id}|${dateOnly}`;
        dayMinutesByUserDay[key] = (dayMinutesByUserDay[key] ?? 0) + minutes;
      }

      const dailyThresholdMinutes = rules.daily_ot_enabled && rules.daily_threshold_hours != null
        ? Number(rules.daily_threshold_hours) * 60
        : null;
      const weeklyThresholdMinutes = rules.weekly_ot_enabled ? Number(rules.weekly_threshold_hours ?? 40) * 60 : null;

      for (const userId of Object.keys(nameByUserId)) {
        const todayMinutes = dayMinutesByUserDay[`${userId}|${todayStr}`] ?? 0;

        let weekMinutes = 0;
        for (let i = 0; i < 7; i++) {
          const d = new Date(`${weekStartStr}T00:00:00.000Z`);
          d.setUTCDate(d.getUTCDate() + i);
          const dStr = d.toISOString().substring(0, 10);
          weekMinutes += dayMinutesByUserDay[`${userId}|${dStr}`] ?? 0;
        }

        const employeeName = nameByUserId[userId];
        const events: Array<{ type: string; periodKey: string; minutes: number; threshold: number }> = [];

        if (dailyThresholdMinutes != null) {
          if (todayMinutes >= dailyThresholdMinutes) {
            events.push({ type: 'daily_crossed', periodKey: todayStr, minutes: todayMinutes, threshold: dailyThresholdMinutes });
          } else if (dailyThresholdMinutes - todayMinutes <= APPROACHING_BUFFER_MINUTES) {
            events.push({ type: 'daily_approaching', periodKey: todayStr, minutes: todayMinutes, threshold: dailyThresholdMinutes });
          }
        }
        if (weeklyThresholdMinutes != null) {
          if (weekMinutes >= weeklyThresholdMinutes) {
            events.push({ type: 'weekly_crossed', periodKey: weekStartStr, minutes: weekMinutes, threshold: weeklyThresholdMinutes });
          } else if (weeklyThresholdMinutes - weekMinutes <= APPROACHING_BUFFER_MINUTES) {
            events.push({ type: 'weekly_approaching', periodKey: weekStartStr, minutes: weekMinutes, threshold: weeklyThresholdMinutes });
          }
        }

        for (const ev of events) {
          const { data: existing } = await db
            .from('overtime_notifications')
            .select('id')
            .eq('business_id', biz.id)
            .eq('user_id', userId)
            .eq('notification_type', ev.type)
            .eq('period_key', ev.periodKey)
            .maybeSingle();
          if (existing) continue;

          await sendOvertimeEmail({
            ownerEmail: biz.owner_email,
            businessName: biz.business_name ?? 'NexaFlow',
            employeeName,
            kind: ev.type as 'daily_approaching' | 'daily_crossed' | 'weekly_approaching' | 'weekly_crossed',
            minutesLogged: ev.minutes,
            thresholdMinutes: ev.threshold,
          });

          await db.from('overtime_notifications').insert({
            business_id: biz.id,
            user_id: userId,
            notification_type: ev.type,
            period_key: ev.periodKey,
          });

          sentCount += 1;
          results.push({ business_id: biz.id, user_id: userId, type: ev.type, period_key: ev.periodKey });
        }
      }
    }

    return new Response(JSON.stringify({ checked: businesses.length, sent: sentCount, results }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    console.error('check-overtime-thresholds error:', e);
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    });
  }
});