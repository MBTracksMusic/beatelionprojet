/*
  # Fix signup trigger robustness: handle_new_user

  Why:
  - Supabase signup can fail with `Database error saving new user` when trigger insert fails.
  - Current username generation can collide with UNIQUE(user_profiles.username).

  What:
  - Recreate public.handle_new_user() with robust unique username generation.
  - Keep SECURITY DEFINER + trigger architecture on auth.users.
  - Add explicit exception message for easier diagnostics.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_base_username text;
  v_username_candidate text;
  v_attempt integer := 0;
BEGIN
  -- Build a stable base username from metadata/email and normalize it.
  v_base_username := lower(
    COALESCE(
      NULLIF(btrim(NEW.raw_user_meta_data->>'username'), ''),
      NULLIF(split_part(COALESCE(NEW.email, ''), '@', 1), ''),
      'user'
    )
  );

  -- Keep only safe username characters.
  v_base_username := regexp_replace(v_base_username, '[^a-z0-9_]+', '_', 'g');
  v_base_username := regexp_replace(v_base_username, '^_+|_+$', '', 'g');
  v_base_username := NULLIF(v_base_username, '');

  IF v_base_username IS NULL THEN
    v_base_username := 'user';
  END IF;

  v_username_candidate := v_base_username;

  -- Ensure uniqueness against UNIQUE(user_profiles.username).
  LOOP
    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.username = v_username_candidate
    );

    v_attempt := v_attempt + 1;
    v_username_candidate := v_base_username || '_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

    IF v_attempt >= 10 THEN
      RAISE EXCEPTION 'unable_to_generate_unique_username';
    END IF;
  END LOOP;

  INSERT INTO public.user_profiles (id, email, username, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.email, ''),
    v_username_candidate,
    'user'
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
EXCEPTION
  WHEN others THEN
    RAISE EXCEPTION 'handle_new_user failed for auth.users id=% email=%: %', NEW.id, COALESCE(NEW.email, '<null>'), SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

COMMIT;
