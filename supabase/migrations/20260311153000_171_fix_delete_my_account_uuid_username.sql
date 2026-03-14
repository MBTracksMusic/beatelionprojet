/*
  # Fix delete_my_account anonymized username generation

  - Replaces legacy byte-based random generation with UUID-based usernames.
  - Keeps soft-delete/anonymization behavior intact.
  - Safe to run on already-migrated environments.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.delete_my_account(p_reason text DEFAULT NULL)
RETURNS TABLE (
  success boolean,
  status text,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_profile public.user_profiles%ROWTYPE;
  v_deleted_username text;
  v_attempt integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth_required';
  END IF;

  SELECT *
  INTO v_profile
  FROM public.user_profiles
  WHERE id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found';
  END IF;

  IF COALESCE(v_profile.is_deleted, false) = true OR v_profile.deleted_at IS NOT NULL THEN
    RETURN QUERY
    SELECT
      true,
      'already_deleted'::text,
      'Account already deleted.'::text;
    RETURN;
  END IF;

  LOOP
    -- UUID-based anonymized username: robust and extension-stable on Supabase.
    v_deleted_username := 'deleted_' || gen_random_uuid()::text;

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.username = v_deleted_username
    );

    v_attempt := v_attempt + 1;
    IF v_attempt >= 8 THEN
      RAISE EXCEPTION 'unable_to_generate_deleted_username';
    END IF;
  END LOOP;

  UPDATE public.user_profiles
  SET
    username = v_deleted_username,
    full_name = NULL,
    avatar_url = NULL,
    bio = NULL,
    website_url = NULL,
    social_links = '{}'::jsonb,
    is_producer_active = false,
    is_deleted = true,
    deleted_at = now(),
    delete_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    deleted_label = 'Deleted Producer',
    updated_at = now()
  WHERE id = v_user_id;

  IF to_regclass('public.cart_items') IS NOT NULL THEN
    DELETE FROM public.cart_items WHERE user_id = v_user_id;
  END IF;

  IF to_regclass('public.wishlists') IS NOT NULL THEN
    DELETE FROM public.wishlists WHERE user_id = v_user_id;
  END IF;

  RETURN QUERY
  SELECT
    true,
    'deleted'::text,
    'Account deleted and anonymized.'::text;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_my_account(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_my_account(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_account(text) TO service_role;

COMMIT;
