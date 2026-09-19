-- Security fix: business_usage_live was defined as a SECURITY DEFINER
-- view, meaning it always reads as its owner (postgres) no matter who
-- queries it. That let it bypass the business_usage_owner_select RLS
-- rule on the underlying business_usage table, so anyone -- including a
-- logged-out visitor using the public anon key -- could read every
-- business's AI-message and campaign-send usage numbers.
--
-- Fix: switch the view to security_invoker, so it runs with the
-- permissions of whoever is actually asking. That makes it respect the
-- existing RLS on business_usage (only an owner/admin of that business
-- can see its rows) and on businesses. We also explicitly revoke the
-- anonymous role's access to the view, since a logged-out visitor should
-- never see this at all.

ALTER VIEW public.business_usage_live SET (security_invoker = true);

REVOKE SELECT ON public.business_usage_live FROM anon;
