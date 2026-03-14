/*
  # Non-blocking event publishing for auth/users profile triggers

  Goal:
  - Ensure user signup/profile updates are not rolled back by event pipeline failures.
  - Keep trigger side-effects best-effort with SQL diagnostics via RAISE NOTICE.
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Harden publish_event() so caller triggers never fail fatally
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_event(
  p_event_type text,
  p_user_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_event_type text := upper(COALESCE(NULLIF(btrim(p_event_type), ''), ''));
  v_aggregate_type text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_type', '')), '');
  v_aggregate_id uuid;
  v_event_id uuid;
  v_outbox public.event_outbox%ROWTYPE;
  v_source_table text := NULLIF(btrim(COALESCE(v_payload->>'source_table', v_payload->>'source', '')), '');
  v_source_record_id uuid;
  v_dedupe_key text := NULLIF(btrim(COALESCE(v_payload->>'dedupe_key', '')), '');
  v_aggregate_id_text text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_id', '')), '');
  v_source_record_id_text text := NULLIF(btrim(COALESCE(v_payload->>'source_record_id', '')), '');
BEGIN
  IF v_event_type = '' THEN
    RAISE EXCEPTION 'event_type_required';
  END IF;

  IF v_aggregate_id_text IS NOT NULL THEN
    BEGIN
      v_aggregate_id := v_aggregate_id_text::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_aggregate_id := NULL;
    END;
  END IF;

  IF v_source_record_id_text IS NOT NULL THEN
    BEGIN
      v_source_record_id := v_source_record_id_text::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_source_record_id := NULL;
    END;
  END IF;

  IF v_aggregate_id IS NULL AND p_user_id IS NOT NULL
    AND v_event_type IN ('USER_SIGNUP', 'USER_CONFIRMED', 'PRODUCER_ACTIVATED') THEN
    v_aggregate_id := p_user_id;
    IF v_aggregate_type IS NULL THEN
      v_aggregate_type := 'user';
    END IF;
  END IF;

  v_outbox := public.publish_outbox_event(
    p_event_type => v_event_type,
    p_user_id => p_user_id,
    p_aggregate_type => v_aggregate_type,
    p_aggregate_id => v_aggregate_id,
    p_payload => v_payload,
    p_source_table => v_source_table,
    p_source_record_id => v_source_record_id,
    p_dedupe_key => v_dedupe_key
  );

  IF v_outbox.event_id IS NOT NULL THEN
    RETURN v_outbox.event_id;
  END IF;

  INSERT INTO public.event_bus (
    event_type,
    aggregate_type,
    aggregate_id,
    user_id,
    payload,
    status,
    source_outbox_id
  )
  VALUES (
    v_event_type,
    v_aggregate_type,
    v_aggregate_id,
    p_user_id,
    v_payload || jsonb_build_object('outbox_id', v_outbox.id),
    'pending',
    v_outbox.id
  )
  ON CONFLICT (source_outbox_id) DO UPDATE
    SET source_outbox_id = EXCLUDED.source_outbox_id
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT eb.id
    INTO v_event_id
    FROM public.event_bus eb
    WHERE eb.source_outbox_id = v_outbox.id
    ORDER BY eb.created_at DESC
    LIMIT 1;
  END IF;

  IF v_event_id IS NULL THEN
    SELECT eb.id
    INTO v_event_id
    FROM public.event_bus eb
    WHERE eb.event_type = v_event_type
      AND eb.aggregate_id IS NOT DISTINCT FROM v_aggregate_id
      AND eb.user_id IS NOT DISTINCT FROM p_user_id
    ORDER BY eb.created_at DESC
    LIMIT 1;
  END IF;

  IF v_event_id IS NOT NULL THEN
    UPDATE public.event_outbox
    SET event_id = v_event_id
    WHERE id = v_outbox.id
      AND event_id IS NULL;
  END IF;

  RETURN v_event_id;
EXCEPTION
  WHEN others THEN
    RAISE NOTICE 'publish_event failed (event_type=%, user_id=%): %',
      COALESCE(v_event_type, '<null>'),
      COALESCE(p_user_id::text, '<null>'),
      SQLERRM;
    RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- 2) Make producer activation trigger non-blocking
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_producer_activated_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_profile jsonb := to_jsonb(NEW);
  v_old_profile jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  v_new_account_type text := lower(COALESCE(v_new_profile->>'account_type', ''));
  v_old_account_type text := lower(COALESCE(v_old_profile->>'account_type', ''));
  v_new_role text := lower(COALESCE(v_new_profile->>'role', ''));
  v_old_role text := lower(COALESCE(v_old_profile->>'role', ''));
  v_new_is_active boolean := lower(COALESCE(v_new_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_old_is_active boolean := lower(COALESCE(v_old_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_new_is_producer boolean;
  v_old_is_producer boolean;
  v_email text;
BEGIN
  BEGIN
    v_new_is_producer := v_new_account_type = 'producer' OR v_new_role = 'producer' OR v_new_is_active;
    v_old_is_producer := v_old_account_type = 'producer' OR v_old_role = 'producer' OR v_old_is_active;

    IF v_new_is_producer AND NOT v_old_is_producer THEN
      v_email := lower(trim(COALESCE(NEW.email, '')));
      PERFORM public.publish_event(
        'PRODUCER_ACTIVATED',
        NEW.id,
        jsonb_build_object(
          'aggregate_type', 'user_profile',
          'aggregate_id', NEW.id,
          'email', v_email,
          'role', NEW.role,
          'is_producer_active', NEW.is_producer_active
        )
      );
    END IF;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'publish_producer_activated_event failed for user_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_user_profile_producer_activated_publish_event ON public.user_profiles;
CREATE TRIGGER on_user_profile_producer_activated_publish_event
  AFTER INSERT OR UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_producer_activated_event();

COMMIT;
