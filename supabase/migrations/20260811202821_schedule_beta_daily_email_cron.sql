select cron.schedule(
  'beta-daily-email',
  '0 16 * * 1,3,5',
  $cmd$
  SELECT net.http_post(
    url := 'https://rllriopqojaraceytdno.supabase.co/functions/v1/beta-daily-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', '4e7946e7a5bc78b6b9159b5d62d05d57e21a04942d28be93'),
    body := '{}'::jsonb
  );
  $cmd$
);