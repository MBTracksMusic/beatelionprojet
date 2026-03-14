/*
  # Admin access self-heal + secure bootstrap

  Goals:
  - Recreate missing user_profiles rows for existing auth.users.
  - Keep profile creation robust for new users.
  - Auto-restore admin role for configured admin emails only after email confirmation.
  - Harden is_admin() so deleted accounts never pass admin checks.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Bootstrap email source for admin recovery
-- ---------------------------------------------------------------------------
-- Supported app_settings formats for key `admin_bootstrap_emails`:
-- - ["admin@beatelion.com", "..."]
-- - {"emails": ["admin@beatelion.com", "..."]}
CREATE OR REPLACE FUNCTION public.get_admin_bootstrap_emails()
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email_json jsonb := '[]'::jsonb;
  v_email text;
  v_result text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.app_settings') IS NOT NULL THEN
    SELECT
      CASE
        WHEN jsonb_typeof(s.value) = 'array' THEN s.value
        WHEN jsonb_typeof(s.value) = 'object'
             AND jsonb_typeof(s.value -> 'emails') = 'array'
          THEN s.value -> 'emails'
        ELSE '[]'::jsonb
      END
    INTO v_email_json
    FROM public.app_settings s
    WHERE s.key = 'admin_bootstrap_emails'
    LIMIT 1;
  END IF;

  FOR v_email IN
    SELECT lower(btrim(value))
    FROM jsonb_array_elements_text(COALESCE(v_email_json, '[]'::jsonb)) AS value
    WHERE btrim(value) <> ''
  LOOP
    IF NOT (v_email = ANY(v_result)) THEN
      v_result := array_append(v_result, v_email);
    END IF;
  END LOOP;

  -- Keep already-known active admins recoverable (no hard lockout on profile drift).
  FOR v_email IN
    SELECT lower(btrim(au.email))
    FROM public.user_profiles up
    JOIN auth.users au ON au.id = up.id
    WHERE up.role = 'admin'::public.user_role
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
      AND au.email IS NOT NULL
      AND btrim(au.email) <> ''
  LOOP
    IF NOT (v_email = ANY(v_result)) THEN
      v_result := array_append(v_result, v_email);
    END IF;
  END LOOP;

  -- Safe default mailbox for BeatElion admin bootstrap.
  IF NOT ('admin@beatelion.com' = ANY(v_result)) THEN
    v_result := array_append(v_result, 'admin@beatelion.com');
  END IF;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Canonical helper: create/repair one profile from auth.users row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_profile_for_auth_user(
  p_user_id uuid,
  p_email text,
  p_email_confirmed_at timestamptz,
  p_raw_username text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base_username text;
  v_username_candidate text;
  v_attempt integer := 0;
  v_email_to_store text := NULLIF(btrim(COALESCE(p_email, '')), '');
  v_normalized_email text := lower(COALESCE(v_email_to_store, ''));
  v_admin_emails text[] := public.get_admin_bootstrap_emails();
  v_promote_admin boolean := false;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  v_promote_admin :=
    p_email_confirmed_at IS NOT NULL
    AND v_normalized_email <> ''
    AND v_normalized_email = ANY(v_admin_emails);

  v_base_username := lower(
    COALESCE(
      NULLIF(btrim(p_raw_username), ''),
      NULLIF(split_part(v_normalized_email, '@', 1), ''),
      'user'
    )
  );

  v_base_username := regexp_replace(v_base_username, '[^a-z0-9_]+', '_', 'g');
  v_base_username := regexp_replace(v_base_username, '^_+|_+$', '', 'g');
  v_base_username := NULLIF(v_base_username, '');

  IF v_base_username IS NULL THEN
    v_base_username := 'user';
  END IF;

  v_username_candidate := v_base_username;

  LOOP
    BEGIN
      INSERT INTO public.user_profiles (id, email, username, role)
      VALUES (
        p_user_id,
        COALESCE(v_email_to_store, ''),
        v_username_candidate,
        CASE
          WHEN v_promote_admin THEN 'admin'::public.user_role
          ELSE 'user'::public.user_role
        END
      )
      ON CONFLICT (id) DO UPDATE
      SET
        email = CASE
          WHEN EXCLUDED.email <> '' THEN EXCLUDED.email
          ELSE public.user_profiles.email
        END,
        role = CASE
          WHEN v_promote_admin THEN 'admin'::public.user_role
          ELSE public.user_profiles.role
        END,
        updated_at = now();

      EXIT;
    EXCEPTION
      WHEN unique_violation THEN
        -- If profile already exists for this auth user, converge and continue.
        IF EXISTS (
          SELECT 1
          FROM public.user_profiles up
          WHERE up.id = p_user_id
        ) THEN
          UPDATE public.user_profiles
          SET
            email = CASE
              WHEN COALESCE(v_email_to_store, '') <> '' THEN v_email_to_store
              ELSE email
            END,
            role = CASE
              WHEN v_promote_admin THEN 'admin'::public.user_role
              ELSE role
            END,
            updated_at = now()
          WHERE id = p_user_id;
          EXIT;
        END IF;

        v_attempt := v_attempt + 1;
        v_username_candidate := v_base_username || '_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

        IF v_attempt >= 8 THEN
          RAISE NOTICE 'ensure_profile_for_auth_user unique retry exhausted for user_id=%', p_user_id;
          EXIT;
        END IF;
    END;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Keep signup trigger non-blocking, but routed through canonical helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  BEGIN
    PERFORM public.ensure_profile_for_auth_user(
      NEW.id,
      NEW.email,
      NEW.email_confirmed_at,
      NEW.raw_user_meta_data->>'username'
    );
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'handle_new_user failed for user_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- Also react when auth email gets confirmed or changed.
CREATE OR REPLACE FUNCTION public.handle_auth_user_profile_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  BEGIN
    PERFORM public.ensure_profile_for_auth_user(
      NEW.id,
      NEW.email,
      NEW.email_confirmed_at,
      NEW.raw_user_meta_data->>'username'
    );
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'handle_auth_user_profile_sync failed for user_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_profile_sync ON auth.users;
CREATE TRIGGER on_auth_user_profile_sync
  AFTER UPDATE OF email, email_confirmed_at, raw_user_meta_data ON auth.users
  FOR EACH ROW
  WHEN (
    OLD.email IS DISTINCT FROM NEW.email
    OR OLD.email_confirmed_at IS DISTINCT FROM NEW.email_confirmed_at
    OR OLD.raw_user_meta_data IS DISTINCT FROM NEW.raw_user_meta_data
  )
  EXECUTE FUNCTION public.handle_auth_user_profile_sync();

-- ---------------------------------------------------------------------------
-- 4) Harden is_admin(): deleted accounts can never be treated as admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid uuid := COALESCE(p_user_id, auth.uid());
BEGIN
  IF uid IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = uid
      AND up.role = 'admin'::public.user_role
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 5) Seed bootstrap key (idempotent) + backfill existing auth users
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.app_settings') IS NOT NULL THEN
    INSERT INTO public.app_settings (key, value)
    VALUES (
      'admin_bootstrap_emails',
      jsonb_build_object('emails', jsonb_build_array('admin@beatelion.com'))
    )
    ON CONFLICT (key) DO NOTHING;
  END IF;
END
$$;

DO $$
DECLARE
  v_auth_user record;
BEGIN
  FOR v_auth_user IN
    SELECT
      au.id,
      au.email,
      au.email_confirmed_at,
      au.raw_user_meta_data->>'username' AS username
    FROM auth.users au
  LOOP
    PERFORM public.ensure_profile_for_auth_user(
      v_auth_user.id,
      v_auth_user.email,
      v_auth_user.email_confirmed_at,
      v_auth_user.username
    );
  END LOOP;
END
$$;

COMMIT;
