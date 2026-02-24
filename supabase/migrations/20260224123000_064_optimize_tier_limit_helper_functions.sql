/*
  # Step 2 correction - Optimize tier limit helper functions

  Scope:
  - Replaces function bodies for:
    - public.can_create_product(uuid)
    - public.can_create_battle(uuid)
  - Keeps behavior, permissions, and safety guards unchanged.

  Notes:
  - Assumes public.products.deleted_at exists (no information_schema checks).
  - No RLS, Stripe, webhook, or index changes.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.can_create_product(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := current_setting('request.jwt.claim.role', true);
  v_tier public.producer_tier_type;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Prevent cross-user probing outside service_role context.
  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
  ) THEN
    RETURN false;
  END IF;

  SELECT up.producer_tier
  INTO v_tier
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_tier IN ('pro', 'elite') THEN
    RETURN true;
  END IF;

  IF v_tier <> 'starter' THEN
    RETURN false;
  END IF;

  -- Starter limit: max 5 active products.
  -- If the 5th row exists (offset 4), creation is denied.
  PERFORM 1
  FROM public.products p
  WHERE p.producer_id = p_user_id
    AND p.deleted_at IS NULL
  OFFSET 4
  LIMIT 1;

  IF FOUND THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := current_setting('request.jwt.claim.role', true);
  v_tier public.producer_tier_type;
  v_month_start timestamptz := date_trunc('month', now());
  v_next_month_start timestamptz := date_trunc('month', now()) + interval '1 month';
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Prevent cross-user probing outside service_role context.
  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
  ) THEN
    RETURN false;
  END IF;

  SELECT up.producer_tier
  INTO v_tier
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_tier IN ('pro', 'elite') THEN
    RETURN true;
  END IF;

  IF v_tier <> 'starter' THEN
    RETURN false;
  END IF;

  -- Starter limit: max 1 created battle per current month.
  PERFORM 1
  FROM public.battles b
  WHERE b.producer1_id = p_user_id
    AND b.created_at >= v_month_start
    AND b.created_at < v_next_month_start
  LIMIT 1;

  IF FOUND THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.can_create_product(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_create_product(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_create_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_product(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.can_create_battle(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_create_battle(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_create_battle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_battle(uuid) TO service_role;

COMMIT;
