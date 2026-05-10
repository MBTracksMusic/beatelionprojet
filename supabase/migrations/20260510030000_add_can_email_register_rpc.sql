-- Adds public.can_email_register(p_email text) → boolean
-- Called by Register.tsx (anon context) before creating a Supabase auth account.
-- Returns true when the given email is allowed to register given the current
-- site_access_mode.  Returns only a boolean — no enumeration risk.
CREATE OR REPLACE FUNCTION public.can_email_register(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(trim(p_email));
  v_mode  text;
BEGIN
  IF v_email IS NULL OR v_email = '' THEN
    RETURN true;
  END IF;

  SELECT site_access_mode INTO v_mode FROM public.settings LIMIT 1;
  v_mode := COALESCE(v_mode, 'private');

  IF v_mode = 'public' THEN
    RETURN true;
  END IF;

  IF v_mode = 'private' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.access_whitelist
      WHERE lower(email) = v_email AND is_active = true
    );
  END IF;

  -- controlled: whitelist OR accepted waitlist
  RETURN EXISTS (
    SELECT 1 FROM public.access_whitelist
    WHERE lower(email) = v_email AND is_active = true
  ) OR EXISTS (
    SELECT 1 FROM public.waitlist
    WHERE lower(email) = v_email AND status = 'accepted'
  );
END;
$$;

COMMENT ON FUNCTION public.can_email_register(text) IS
  'Returns true when the given email is allowed to register under the current site_access_mode. Safe for anon callers — returns only boolean.';

GRANT EXECUTE ON FUNCTION public.can_email_register(text) TO anon, authenticated;
