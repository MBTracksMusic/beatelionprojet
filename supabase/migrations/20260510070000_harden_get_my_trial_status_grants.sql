-- Harden get_my_trial_status: authenticated-only.
-- The function uses auth.uid() and returns NULL for unauthenticated callers —
-- anon access serves no purpose and is a security linter violation.
-- Idempotent: safe even if migration 20260510000000 already ran these grants.
REVOKE ALL ON FUNCTION public.get_my_trial_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_trial_status() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_trial_status() TO authenticated;
