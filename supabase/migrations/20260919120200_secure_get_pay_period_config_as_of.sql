-- Security fix: get_pay_period_config_as_of had no check on who was
-- asking, so any caller (any logged-in user, or even the anon key) could
-- pass any business_id and read that business's pay-period settings.
--
-- Fix: the function now only answers for:
--   - a user who belongs to that business (any team member -- this
--     matches how the office Timesheets screen calls it),
--   - a superuser (matches every other "own business" rule in this app,
--     e.g. the businesses_select policy), or
--   - a call made with the service-role key, which is how
--     get-employee-hub-data calls it on behalf of an employee using the
--     unauthenticated Employee Hub link -- that function already
--     resolves the correct business_id server-side from a validated
--     hub token before it ever reaches this function.

CREATE OR REPLACE FUNCTION public.get_pay_period_config_as_of(p_business_id bigint, p_target_date date DEFAULT CURRENT_DATE)
 RETURNS TABLE(week_start_day text, pay_period_type text, pay_period_config jsonb, effective_date date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.role() <> 'service_role'
     AND get_my_business_id() IS DISTINCT FROM p_business_id
     AND NOT is_super_admin() THEN
    RAISE EXCEPTION 'Not authorized for this business';
  END IF;

  RETURN QUERY
  SELECT h.week_start_day, h.pay_period_type, h.pay_period_config, h.effective_date
  FROM public.business_pay_period_config_history h
  WHERE h.business_id = p_business_id
    AND h.deleted_at IS NULL
    AND h.effective_date <= p_target_date
  ORDER BY h.effective_date DESC, h.created_at DESC
  LIMIT 1;
END;
$function$;

-- Nothing legitimate ever calls this while logged out, so the anonymous
-- key doesn't need to be able to reach it at all.
REVOKE EXECUTE ON FUNCTION public.get_pay_period_config_as_of(bigint, date) FROM anon;
