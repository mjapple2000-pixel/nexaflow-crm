CREATE TABLE public.cron_run_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  function_name text NOT NULL,
  ran_at timestamptz NOT NULL DEFAULT now(),
  success boolean NOT NULL,
  detail jsonb,
  deleted_at timestamptz
);

CREATE INDEX idx_cron_run_log_function_name_ran_at ON public.cron_run_log (function_name, ran_at DESC);

ALTER TABLE public.cron_run_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Superusers can view cron run log"
  ON public.cron_run_log
  FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.superusers WHERE user_id = auth.uid()));

GRANT ALL ON public.cron_run_log TO authenticated;
GRANT ALL ON public.cron_run_log TO service_role;
GRANT ALL ON SEQUENCE public.cron_run_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.cron_run_log_id_seq TO service_role;