SELECT cron.schedule(
  'daily-ticket-digest',
  '0 14 * * *',
  $$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/daily-ticket-digest',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $$
);

SELECT cron.schedule(
  'cron-heartbeat',
  '0 15 * * 1',
  $$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/cron-heartbeat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $$
);