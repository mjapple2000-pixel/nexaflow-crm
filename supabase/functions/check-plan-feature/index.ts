import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// ── Plan feature matrix ──────────────────────────────────────────────────────
// Source of truth for what each tier unlocks.
// When adding a new gated feature, add its key here before wiring it up.
const PLAN_FEATURES: Record<string, string[]> = {
  starter: [
    'sms',
    'unified_inbox',
    'pipeline',
    'automations_basic',
    'missed_call_text_back',
    'ai_receptionist',
    'review_requests',
    'contact_timeline',
    'appointment_reminders',
  ],
  growth: [
    // Includes everything in starter
    'sms',
    'unified_inbox',
    'pipeline',
    'automations_basic',
    'missed_call_text_back',
    'ai_receptionist',
    'review_requests',
    'contact_timeline',
    'appointment_reminders',
    // Growth-only
    'ai_suite_full',
    'ai_sales_coach',
    'ai_lead_responder',
    'ai_appointment_assistant',
    'ai_review_responses',
    'custom_workflows',
    'multiple_pipelines',
    'api_access',
    'automations_advanced',
    'campaigns',
  ],
  pro: [
    // Includes everything in growth
    'sms',
    'unified_inbox',
    'pipeline',
    'automations_basic',
    'missed_call_text_back',
    'ai_receptionist',
    'review_requests',
    'contact_timeline',
    'appointment_reminders',
    'ai_suite_full',
    'ai_sales_coach',
    'ai_lead_responder',
    'ai_appointment_assistant',
    'ai_review_responses',
    'custom_workflows',
    'multiple_pipelines',
    'api_access',
    'automations_advanced',
    'campaigns',
    // Pro-only
    'priority_support',
    'sms_unlimited',
    'analytics_advanced',
    'white_label',
    'dedicated_onboarding',
  ],
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // ── Auth: resolve the calling user's business ──────────────────────────
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ allowed: false, reason: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    )

    const { data: { user } } = await userClient.auth.getUser()
    if (!user) {
      return new Response(
        JSON.stringify({ allowed: false, reason: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Resolve business_id from profile ──────────────────────────────────
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    const { data: profile } = await supabase
      .from('profiles')
      .select('business_id')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!profile?.business_id) {
      return new Response(
        JSON.stringify({ allowed: false, reason: 'No business found' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const businessId: number = profile.business_id

    // ── Parse the feature being checked ───────────────────────────────────
    const body = await req.json()
    const featureName: string = body.feature

    if (!featureName) {
      return new Response(
        JSON.stringify({ allowed: false, reason: 'feature parameter required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Load the business record ───────────────────────────────────────────
    const { data: business } = await supabase
      .from('businesses')
      .select('plan, subscription_status, is_paid, is_beta')
      .eq('id', businessId)
      .maybeSingle()

    if (!business) {
      return new Response(
        JSON.stringify({ allowed: false, reason: 'Business not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Beta users get full access to everything ───────────────────────────
    if (business.is_beta === true) {
      return new Response(
        JSON.stringify({ allowed: true, plan: 'beta', feature: featureName }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Non-paying businesses: no gated features ──────────────────────────
    if (!business.is_paid) {
      return new Response(
        JSON.stringify({
          allowed: false,
          reason: 'No active subscription',
          plan: null,
          feature: featureName,
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Cancelled / past_due subscriptions: block gated features ──────────
    const activeStatuses = ['active', 'trialing']
    if (!activeStatuses.includes(business.subscription_status ?? '')) {
      return new Response(
        JSON.stringify({
          allowed: false,
          reason: `Subscription is ${business.subscription_status}`,
          plan: business.plan,
          feature: featureName,
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    // ── Check feature against plan matrix ─────────────────────────────────
    const plan: string = business.plan ?? 'starter'
    const allowedFeatures = PLAN_FEATURES[plan] ?? PLAN_FEATURES['starter']
    const allowed = allowedFeatures.includes(featureName)

    return new Response(
      JSON.stringify({
        allowed,
        plan,
        feature: featureName,
        reason: allowed ? undefined : `Feature '${featureName}' not included in ${plan} plan`,
      }),
      {
        status: allowed ? 200 : 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      },
    )
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : 'Unknown error'
    return new Response(
      JSON.stringify({ allowed: false, reason: message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})