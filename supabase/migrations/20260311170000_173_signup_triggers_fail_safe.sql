/*
  # Make signup triggers fail-safe (non-blocking)

  Goal:
  - Prevent `Database error saving new user` when downstream trigger logic fails.
  - Keep `auth.users` insertion successful even if profile/event side effects fail.

  Scope:
  - public.handle_new_user()
  - public.publish_user_signup_event()
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Robust, non-blocking profile creation trigger
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_username text;
  v_username_candidate text;
  v_attempt integer := 0;
BEGIN
  v_base_username := lower(
    COALESCE(
      NULLIF(btrim(NEW.raw_user_meta_data->>'username'), ''),
      NULLIF(split_part(COALESCE(NEW.email, ''), '@', 1), ''),
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
        NEW.id,
        COALESCE(NEW.email, ''),
        v_username_candidate,
        'user'
      );
      EXIT;
    EXCEPTION
      WHEN unique_violation THEN
        -- If profile already exists for this auth user, signup should continue.
        IF EXISTS (
          SELECT 1
          FROM public.user_profiles up
          WHERE up.id = NEW.id
        ) THEN
          EXIT;
        END IF;

        v_attempt := v_attempt + 1;
        v_username_candidate := 'user_' || replace(gen_random_uuid()::text, '-', '');

        IF v_attempt >= 8 THEN
          RAISE NOTICE 'handle_new_user unique retry exhausted for user_id=%', NEW.id;
          EXIT;
        END IF;
    END;
  END LOOP;

  RETURN NEW;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE 'handle_new_user failed for user_id=%: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 2) Non-blocking signup event publish trigger
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_user_signup_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.publish_event(
      'USER_SIGNUP',
      NEW.id,
      jsonb_build_object(
        'aggregate_type', 'user',
        'aggregate_id', NEW.id,
        'email', lower(trim(COALESCE(NEW.email, '')))
      )
    );
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'publish_event failed for USER_SIGNUP user_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_publish_event ON auth.users;
CREATE TRIGGER on_auth_user_created_publish_event
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_user_signup_event();

COMMIT;
