-- Security fix: create_beta_business had no check on who was calling it.
-- Because it is SECURITY DEFINER, anyone holding the public anon API key
-- -- logged in or not -- could call it directly with made-up parameters
-- and hijack someone else's pending beta invite, or spam fake businesses.
--
-- Fix: the function now only completes a beta signup when the caller is
-- actually logged in as the exact user (p_user_id) it's being run for,
-- and only against an invite (p_beta_tester_id) that is still open,
-- unexpired, and matches both p_email and the caller's own account email.
-- This matches the real signup flow in beta_signup_screen.dart, which
-- always signs the user in before calling this function.

CREATE OR REPLACE FUNCTION public.create_beta_business(p_business_name text, p_email text, p_full_name text, p_user_id uuid, p_beta_tester_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_business_id bigint;
BEGIN
  -- Caller must be logged in as the exact user this business is for.
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  -- The invite must exist, still be open, not expired, and belong to this caller.
  IF NOT EXISTS (
    SELECT 1 FROM public.beta_testers bt
    WHERE bt.id = p_beta_tester_id
      AND bt.status = 'invited'
      AND bt.token_expires_at > now()
      AND lower(bt.email) = lower(p_email)
      AND lower(bt.email) = lower(auth.jwt() ->> 'email')
  ) THEN
    RAISE EXCEPTION 'Invalid or expired invite';
  END IF;

  -- Create business
  INSERT INTO public.businesses (business_name, business_email, is_beta, has_logged_in_before)
  VALUES (p_business_name, p_email, true, false)
  RETURNING id INTO v_business_id;

  -- Update the profile the trigger already created
  UPDATE public.profiles
  SET business_id = v_business_id,
      full_name = p_full_name,
      role = 'owner',
      permissions = '{}'
  WHERE user_id = p_user_id;

  -- Update beta_testers
  UPDATE public.beta_testers
  SET status = 'active',
      business_id = v_business_id,
      business_name = p_business_name,
      full_name = p_full_name,
      activated_at = now(),
      invite_token = null
  WHERE id = p_beta_tester_id;

  RETURN v_business_id;
END;
$function$;

-- Nothing legitimate ever calls this before the caller is logged in, so
-- the anonymous key doesn't need to be able to reach it at all.
REVOKE EXECUTE ON FUNCTION public.create_beta_business(text, text, text, uuid, bigint) FROM anon;
