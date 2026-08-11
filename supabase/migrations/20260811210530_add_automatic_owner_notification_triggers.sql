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
      'lead_phone', new.lead_phone
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_owner_new_lead on public.leads;
create trigger trg_notify_owner_new_lead
  after insert on public.leads
  for each row
  execute function public.notify_owner_new_lead();

create or replace function public.notify_owner_new_appointment()
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
      'trigger_type', 'appointment_booked',
      'business_id', new.business_id,
      'lead_name', new.lead_name,
      'lead_email', new.lead_email,
      'lead_phone', new.lead_phone,
      'appointment_time', new.start_date_time
    )
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_owner_new_appointment on public.appointments;
create trigger trg_notify_owner_new_appointment
  after insert on public.appointments
  for each row
  execute function public.notify_owner_new_appointment();