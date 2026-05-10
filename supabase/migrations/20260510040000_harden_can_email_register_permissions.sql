-- Harden can_email_register permissions
-- The function must remain callable by anon because Register.tsx calls it before signup.
-- The authenticated grant added in 20260510030000 is not required for any real use case
-- and triggers the authenticated_security_definer_function_executable linter warning.
-- Scope is intentionally narrow: only permissions, no logic changes.

REVOKE ALL ON FUNCTION public.can_email_register(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_email_register(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.can_email_register(text) TO anon;

COMMENT ON FUNCTION public.can_email_register(text) IS
  'Returns true when an email is allowed to register under the current site access mode. Intentionally executable by anon for pre-signup gate; returns only boolean.';
