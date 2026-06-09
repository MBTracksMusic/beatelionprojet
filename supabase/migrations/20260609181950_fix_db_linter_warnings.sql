/*
  # Fix database linter warnings without changing product behavior

  This migration addresses Supabase/Postgres linter findings only:
  - functions that read request context or call volatile helpers are marked
    VOLATILE instead of STABLE;
  - legacy compatibility parameters and lock records are referenced with no-op
    reads so their public signatures and current behavior remain unchanged.
*/

BEGIN;

-- These helpers depend on auth.uid(), auth.jwt(), now(), or functions that do.
-- Marking them VOLATILE is metadata-only from a business-rules perspective.
ALTER FUNCTION private.forum_current_user_is_admin() VOLATILE;
ALTER FUNCTION public.forum_current_user_is_admin() VOLATILE;

ALTER FUNCTION private.forum_has_active_subscription(uuid) VOLATILE;
ALTER FUNCTION public.forum_has_active_subscription(uuid) VOLATILE;

ALTER FUNCTION private.forum_is_verified_label(uuid) VOLATILE;
ALTER FUNCTION public.forum_is_verified_label(uuid) VOLATILE;

ALTER FUNCTION private.rpc_admin_get_reputation_overview(text, integer) VOLATILE;
ALTER FUNCTION public.rpc_admin_get_reputation_overview(text, integer) VOLATILE;

ALTER FUNCTION public.forum_can_access_category(uuid, uuid) VOLATILE;
ALTER FUNCTION public.forum_can_write_topic(uuid, uuid) VOLATILE;

DO $$
DECLARE
  v_sql text;
  v_updated text;
BEGIN
  -- private.create_new_version_from_beat keeps p_new_data for API compatibility.
  SELECT pg_get_functiondef('private.create_new_version_from_beat(uuid, jsonb)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function private.create_new_version_from_beat(uuid, jsonb) not found';
  END IF;

  IF position('PERFORM p_new_data;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'BEGIN\n  v_new_product_id := public.rpc_create_product_version(p_beat_id);',
      E'BEGIN\n  -- Legacy compatibility argument; intentionally ignored by current versioning flow.\n  PERFORM p_new_data;\n\n  v_new_product_id := public.rpc_create_product_version(p_beat_id);'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch private.create_new_version_from_beat(uuid, jsonb)';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- private.get_battle_feedback_payload uses auth.uid() for viewer lookup.
  -- p_viewer_id is retained for API stability and documented as ignored.
  SELECT pg_get_functiondef('private.get_battle_feedback_payload(uuid, uuid)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function private.get_battle_feedback_payload(uuid, uuid) not found';
  END IF;

  IF position('PERFORM p_viewer_id;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'BEGIN\n  IF p_battle_id IS NULL THEN',
      E'BEGIN\n  -- Legacy compatibility argument; viewer lookup is intentionally based on auth.uid().\n  PERFORM p_viewer_id;\n\n  IF p_battle_id IS NULL THEN'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch private.get_battle_feedback_payload(uuid, uuid)';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- private.purchase_beat_with_credits keeps the legacy p_license_id argument.
  SELECT pg_get_functiondef('private.purchase_beat_with_credits(uuid, uuid)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function private.purchase_beat_with_credits(uuid, uuid) not found';
  END IF;

  IF position('PERFORM p_license_id;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'BEGIN\n  IF v_uid IS NULL THEN',
      E'BEGIN\n  -- Legacy compatibility argument; credit purchases derive the license snapshot internally.\n  PERFORM p_license_id;\n\n  IF v_uid IS NULL THEN'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch private.purchase_beat_with_credits(uuid, uuid)';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- public.rpc_join_waitlist_preflight keeps p_email for the Edge Function API.
  SELECT pg_get_functiondef('public.rpc_join_waitlist_preflight(text, text)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function public.rpc_join_waitlist_preflight(text, text) not found';
  END IF;

  IF position('PERFORM p_email;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'BEGIN\n  -- Plain waitlist (no campaign) follows the launch-mode gate only.',
      E'BEGIN\n  -- Legacy compatibility argument; email validation happens in the Edge Function before this RPC.\n  PERFORM p_email;\n\n  -- Plain waitlist (no campaign) follows the launch-mode gate only.'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch public.rpc_join_waitlist_preflight(text, text)';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- complete_exclusive_purchase locks a row for validation; read the record so
  -- the linter recognizes the lock variable as intentionally consumed.
  SELECT pg_get_functiondef('public.complete_exclusive_purchase(uuid, uuid, text, text, integer)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function public.complete_exclusive_purchase(uuid, uuid, text, text, integer) not found';
  END IF;

  IF position('PERFORM v_lock.id;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'  IF NOT FOUND THEN\n    RAISE EXCEPTION ''No valid lock found for this purchase'';\n  END IF;\n\n  INSERT INTO public.purchases',
      E'  IF NOT FOUND THEN\n    RAISE EXCEPTION ''No valid lock found for this purchase'';\n  END IF;\n\n  PERFORM v_lock.id;\n\n  INSERT INTO public.purchases'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch public.complete_exclusive_purchase(uuid, uuid, text, text, integer)';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- complete_license_purchase also validates or observes an exclusive lock.
  SELECT pg_get_functiondef('public.complete_license_purchase(uuid, uuid, text, text, uuid, integer)'::regprocedure)
  INTO v_sql;

  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'Function public.complete_license_purchase(uuid, uuid, text, text, uuid, integer) not found';
  END IF;

  IF position('PERFORM v_lock.id;' in v_sql) = 0 THEN
    v_updated := replace(
      v_sql,
      E'    IF NOT FOUND THEN\n      RAISE NOTICE ''complete_license_purchase: missing lock for paid exclusive checkout %, product %, user %; proceeding'',\n        p_checkout_session_id, p_product_id, p_user_id;\n    END IF;\n  END IF;\n\n  IF v_license.max_sales IS NOT NULL THEN',
      E'    IF NOT FOUND THEN\n      RAISE NOTICE ''complete_license_purchase: missing lock for paid exclusive checkout %, product %, user %; proceeding'',\n        p_checkout_session_id, p_product_id, p_user_id;\n    END IF;\n\n    PERFORM v_lock.id;\n  END IF;\n\n  IF v_license.max_sales IS NOT NULL THEN'
    );

    IF v_updated = v_sql THEN
      RAISE EXCEPTION 'Could not patch public.complete_license_purchase(uuid, uuid, text, text, uuid, integer)';
    END IF;

    EXECUTE v_updated;
  END IF;
END
$$;

COMMIT;
