select cron.alter_job(
  job_id := 1,
  command := $cmd$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/process-scheduled-automations',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $cmd$
);

select cron.alter_job(
  job_id := 3,
  command := $cmd$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/dispatch-campaign-sms',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $cmd$
);

select cron.alter_job(
  job_id := 7,
  command := $cmd$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/generate-weekly-insight',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $cmd$
);

select cron.schedule(
  'weekly-check-in',
  '0 14 * * 1',
  $cmd$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/weekly-check-in',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $cmd$
);