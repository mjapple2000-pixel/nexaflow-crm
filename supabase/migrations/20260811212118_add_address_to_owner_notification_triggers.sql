create or replace function public.notify_owner_new_lead()
returns trigger
language plpgsql
security definer
as $$
begin
  perform net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/notify-owner',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'
    ),
    body := jsonb_build_object(
      'trigger_type', 'new_lead',
      'business_id', new.business_id,
      'lead_name', new.lead_name,
      'lead_email', new.lead_email,
      'lead_phone', new.lead_phone,
      'lead_address', new.lead_address
    )
  );
  return new;
end;
$$;

create or replace function public.notify_owner_new_appointment()
returns trigger
language plpgsql
security definer
as $$
declare
  matched_address text;
begin
  select lead_address into matched_address
  from public.leads
  where business_id = new.business_id
    and lead_email = new.lead_email
  limit 1;

  perform net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/notify-owner',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'
    ),
    body := jsonb_build_object(
      'trigger_type', 'appointment_booked',
      'business_id', new.business_id,
      'lead_name', new.lead_name,
      'lead_email', new.lead_email,
      'lead_phone', new.lead_phone,
      'lead_address', coalesce(matched_address, new.notes),
      'appointment_time', new.start_date_time
    )
  );
  return new;
end;
$$;