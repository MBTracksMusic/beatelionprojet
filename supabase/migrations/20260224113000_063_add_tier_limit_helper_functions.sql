/*
  # Step 2 - Starter limits helper functions (safe, not wired to RLS yet)

  Scope:
  - Adds `public.can_create_product(p_user_id uuid)`
  - Adds `public.can_create_battle(p_user_id uuid)`
  - Adds non-destructive helper indexes for future policy usage

  Important:
  - Does NOT modify existing RLS policies.
  - Does NOT modify Stripe/webhooks/subscription sync.
  - Keeps `is_producer_active` flow untouched.
*/

BEGIN;

-- Optional performance helper for active products count by producer.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'deleted_at'
  ) THEN
    EXECUTE '
      CREATE INDEX IF NOT EXISTS idx_products_producer_active_not_deleted
      ON public.products (producer_id)
      WHERE deleted_at IS NULL
    ';
  END IF;
END
$$;

-- Optional performance helper for monthly battle count by producer.
CREATE INDEX IF NOT EXISTS idx_battles_producer1_created_at
  ON public.battles (producer1_id, created_at DESC);

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
  v_count bigint := 0;
  v_has_deleted_at boolean := false;
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

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'deleted_at'
  )
  INTO v_has_deleted_at;

  IF v_has_deleted_at THEN
    SELECT COUNT(*)
    INTO v_count
    FROM public.products p
    WHERE p.producer_id = p_user_id
      AND p.deleted_at IS NULL;
  ELSE
    SELECT COUNT(*)
    INTO v_count
    FROM public.products p
    WHERE p.producer_id = p_user_id;
  END IF;

  RETURN v_count < 5;
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
  v_count bigint := 0;
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

  SELECT COUNT(*)
  INTO v_count
  FROM public.battles b
  WHERE b.producer1_id = p_user_id
    AND b.created_at >= v_month_start
    AND b.created_at < v_next_month_start;

  RETURN v_count < 1;
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
