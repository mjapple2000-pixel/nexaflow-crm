import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { calendar_id, date } = await req.json()

    if (!calendar_id || !date) {
      return new Response(
        JSON.stringify({ error: 'calendar_id and date are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const dateRegex = /^\d{4}-\d{2}-\d{2}$/
    if (!dateRegex.test(date)) {
      return new Response(
        JSON.stringify({ error: 'date must be in YYYY-MM-DD format' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Fetch calendar — must be public and active, join business for timezone and name
    const { data: calendar, error: calendarError } = await supabase
      .from('calendars')
      .select('id, business_id, name, duration_minutes, availability_hours, is_public, is_active, booking_page_title, booking_page_description, businesses(business_name, timezone)')
      .eq('id', calendar_id)
      .eq('is_public', true)
      .eq('is_active', true)
      .single()

    if (calendarError || !calendar) {
      return new Response(
        JSON.stringify({ error: 'Calendar not found or not available for public booking' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const businessData = calendar.businesses as any
    const timezone = businessData?.timezone || 'America/New_York'
    const businessName = businessData?.business_name || ''

    // Get the day of week for the requested date in the business's timezone
    const dateInTz = new Date(`${date}T12:00:00.000Z`)
    const dayName = dateInTz.toLocaleDateString('en-US', {
      weekday: 'long',
      timeZone: timezone,
    }).toLowerCase()

    const availability = calendar.availability_hours || {}
    const dayConfig = availability[dayName]

    if (!dayConfig || !dayConfig.enabled) {
      return new Response(
        JSON.stringify({
          slots: [],
          calendar: {
            name: calendar.name,
            business_name: businessName,
            booking_page_title: calendar.booking_page_title,
            booking_page_description: calendar.booking_page_description,
            duration_minutes: calendar.duration_minutes,
            availability_days: Object.entries(availability)
              .filter(([_, cfg]: [string, any]) => cfg?.enabled === true)
              .map(([day]) => day),
          }
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const startTime = dayConfig.start || '09:00'
    const endTime = dayConfig.end || '17:00'
    const durationMinutes = calendar.duration_minutes || 60

    const [startHour, startMin] = startTime.split(':').map(Number)
    const [endHour, endMin] = endTime.split(':').map(Number)

    // Determine UTC offset for the business timezone using Intl DateTimeFormat parts
    // This is DST-safe: we format a known UTC noon into local time and read H+M parts
    const testUtc = new Date(`${date}T12:00:00.000Z`)
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).formatToParts(testUtc)

    const localH = parseInt(parts.find(p => p.type === 'hour')!.value)
    const localM = parseInt(parts.find(p => p.type === 'minute')!.value)
    // Offset in minutes: UTC noon minus what local clock shows
    const offsetMinutes = 12 * 60 - (localH * 60 + localM)

    // Generate slots converting business local time to UTC
    const allSlots: { start: string; end: string }[] = []

    const dayStartUtc = new Date(`${date}T00:00:00.000Z`)
    dayStartUtc.setTime(dayStartUtc.getTime() + (startHour * 60 + startMin + offsetMinutes) * 60 * 1000)

    const dayEndUtc = new Date(`${date}T00:00:00.000Z`)
    dayEndUtc.setTime(dayEndUtc.getTime() + (endHour * 60 + endMin + offsetMinutes) * 60 * 1000)

    const cursor = new Date(dayStartUtc)
    while (cursor.getTime() + durationMinutes * 60 * 1000 <= dayEndUtc.getTime()) {
      const slotEnd = new Date(cursor.getTime() + durationMinutes * 60 * 1000)
      allSlots.push({
        start: cursor.toISOString(),
        end: slotEnd.toISOString(),
      })
      cursor.setTime(cursor.getTime() + durationMinutes * 60 * 1000)
    }

    // Fetch existing appointments for this calendar/business/date
    const dayStartISO = new Date(`${date}T00:00:00.000Z`).toISOString()
    const dayEndISO = new Date(`${date}T23:59:59.999Z`).toISOString()

    const { data: existingAppointments, error: apptError } = await supabase
      .from('appointments')
      .select('start_date_time, end_date_time, status')
      .eq('calendar_id', calendar_id)
      .eq('business_id', calendar.business_id)
      .gte('start_date_time', dayStartISO)
      .lte('start_date_time', dayEndISO)
      .is('deleted_at', null)

    if (apptError) {
      console.error('Error fetching appointments:', apptError)
      return new Response(
        JSON.stringify({ error: 'Failed to fetch availability' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const blockers = (existingAppointments || []).filter(a => !['cancelled', 'rescheduled'].includes(a.status?.toLowerCase() ?? ''))

    const availableSlots = allSlots.filter((slot) => {
      const slotStart = new Date(slot.start).getTime()
      const slotEnd = new Date(slot.end).getTime()
      for (const blocker of blockers) {
        const blockerStart = new Date(blocker.start_date_time).getTime()
        const blockerEnd = new Date(blocker.end_date_time).getTime()
        if (slotStart < blockerEnd && slotEnd > blockerStart) return false
      }
      return true
    })

    const now = Date.now()
    const futureSlots = availableSlots.filter(slot => new Date(slot.start).getTime() > now)

    const enabledDays = Object.entries(availability)
      .filter(([_, cfg]: [string, any]) => cfg?.enabled === true)
      .map(([day]) => day)

    return new Response(
      JSON.stringify({
        slots: futureSlots,
        calendar: {
          name: calendar.name,
          business_name: businessName,
          booking_page_title: calendar.booking_page_title,
          booking_page_description: calendar.booking_page_description,
          duration_minutes: durationMinutes,
          availability_days: enabledDays,
        },
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (err) {
    console.error('Unexpected error:', err)
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})