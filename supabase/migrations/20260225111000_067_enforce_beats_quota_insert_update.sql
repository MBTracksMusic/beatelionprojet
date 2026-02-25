/*
  # Enforce published beats quota on INSERT + UPDATE

  Counted beats:
  - product_type = 'beat'
  - is_published = true
  - deleted_at IS NULL

  Starter quota comes from `public.producer_plans.max_beats_published`.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.get_producer_tier(p_user_id uuid)
RETURNS public.producer_tier_type
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
    RETURN NULL;
  END IF;

  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
  ) THEN
    RETURN NULL;
  END IF;

  SELECT up.producer_tier
  INTO v_tier
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  RETURN v_tier;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_plan_limits(p_tier public.producer_tier_type)
RETURNS TABLE (
  max_beats_published integer,
  max_battles_created_per_month integer,
  commission_rate numeric(5,4),
  stripe_price_id text,
  is_active boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    pp.max_beats_published,
    pp.max_battles_created_per_month,
    pp.commission_rate,
    pp.stripe_price_id,
    pp.is_active
  FROM public.producer_plans pp
  WHERE pp.tier = p_tier
    AND pp.is_active = true
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.can_publish_beat(
  p_user_id uuid,
  p_exclude_product_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tier public.producer_tier_type;
  v_max_beats integer;
  v_count bigint := 0;
BEGIN
  v_tier := public.get_producer_tier(p_user_id);
  IF v_tier IS NULL THEN
    RETURN false;
  END IF;

  SELECT limits.max_beats_published
  INTO v_max_beats
  FROM public.get_plan_limits(v_tier) AS limits;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_max_beats IS NULL THEN
    RETURN true;
  END IF;

  SELECT count(*)
  INTO v_count
  FROM public.products p
  WHERE p.producer_id = p_user_id
    AND p.product_type = 'beat'
    AND p.is_published = true
    AND p.deleted_at IS NULL
    AND (p_exclude_product_id IS NULL OR p.id <> p_exclude_product_id);

  RETURN v_count < v_max_beats;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_product(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public.can_publish_beat(p_user_id, NULL);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_producer_tier(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_producer_tier(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_producer_tier(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_producer_tier(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_plan_limits(public.producer_tier_type) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_plan_limits(public.producer_tier_type) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_plan_limits(public.producer_tier_type) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_plan_limits(public.producer_tier_type) TO service_role;

REVOKE EXECUTE ON FUNCTION public.can_publish_beat(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_publish_beat(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_publish_beat(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_publish_beat(uuid, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.can_create_product(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_create_product(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_create_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_product(uuid) TO service_role;

CREATE INDEX IF NOT EXISTS idx_products_published_beats_by_producer
  ON public.products (producer_id, created_at DESC)
  WHERE product_type = 'beat'
    AND is_published = true
    AND deleted_at IS NULL;

DROP POLICY IF EXISTS "Active producers can create products" ON public.products;
CREATE POLICY "Active producers can create products"
  ON public.products
  FOR INSERT
  TO authenticated
  WITH CHECK (
    producer_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND (
      NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
      OR public.can_publish_beat(auth.uid(), NULL)
    )
  );

DROP POLICY IF EXISTS "Producers can update own unsold products" ON public.products;
CREATE POLICY "Producers can update own unsold products"
  ON public.products
  FOR UPDATE
  TO authenticated
  USING (
    producer_id = auth.uid()
    AND is_sold = false
  )
  WITH CHECK (
    producer_id = auth.uid()
    AND is_sold = false
    AND (
      NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
      OR public.can_publish_beat(auth.uid(), id)
    )
  );

COMMIT;
