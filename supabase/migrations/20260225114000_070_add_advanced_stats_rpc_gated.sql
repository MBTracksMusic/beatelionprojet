/*
  # Add gated advanced producer stats RPC

  - `has_producer_tier(user, min_tier)` helper
  - `get_advanced_producer_stats()` gated to PRO / ELITE
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.producer_tier_rank(p_tier public.producer_tier_type)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'starter'::public.producer_tier_type THEN 1
    WHEN 'pro'::public.producer_tier_type THEN 2
    WHEN 'elite'::public.producer_tier_type THEN 3
    ELSE 0
  END
$$;

CREATE OR REPLACE FUNCTION public.has_producer_tier(
  p_user_id uuid,
  p_min_tier public.producer_tier_type
)
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
  IF p_user_id IS NULL OR p_min_tier IS NULL THEN
    RETURN false;
  END IF;

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

  IF NOT FOUND OR v_tier IS NULL THEN
    RETURN false;
  END IF;

  RETURN public.producer_tier_rank(v_tier) >= public.producer_tier_rank(p_min_tier);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_advanced_producer_stats()
RETURNS TABLE (
  published_beats bigint,
  completed_sales bigint,
  revenue_cents bigint,
  monthly_battles_created bigint,
  sales_per_published_beat numeric(10,4)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT public.has_producer_tier(v_uid, 'pro'::public.producer_tier_type) THEN
    RAISE EXCEPTION 'insufficient_tier' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH beats AS (
    SELECT count(*)::bigint AS published_beats
    FROM public.products p
    WHERE p.producer_id = v_uid
      AND p.product_type = 'beat'
      AND p.is_published = true
      AND p.deleted_at IS NULL
  ),
  sales AS (
    SELECT
      count(*)::bigint AS completed_sales,
      COALESCE(sum(pu.amount), 0)::bigint AS revenue_cents
    FROM public.purchases pu
    WHERE pu.producer_id = v_uid
      AND pu.status = 'completed'
  ),
  monthly_battles AS (
    SELECT count(*)::bigint AS monthly_battles_created
    FROM public.battles b
    WHERE b.producer1_id = v_uid
      AND b.created_at >= date_trunc('month', now())
      AND b.created_at < date_trunc('month', now()) + interval '1 month'
  )
  SELECT
    beats.published_beats,
    sales.completed_sales,
    sales.revenue_cents,
    monthly_battles.monthly_battles_created,
    CASE
      WHEN beats.published_beats > 0
      THEN round((sales.completed_sales::numeric / beats.published_beats::numeric), 4)
      ELSE 0::numeric
    END::numeric(10,4) AS sales_per_published_beat
  FROM beats, sales, monthly_battles;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.has_producer_tier(uuid, public.producer_tier_type) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.has_producer_tier(uuid, public.producer_tier_type) FROM anon;
GRANT EXECUTE ON FUNCTION public.has_producer_tier(uuid, public.producer_tier_type) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_producer_tier(uuid, public.producer_tier_type) TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_advanced_producer_stats() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_advanced_producer_stats() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_advanced_producer_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_advanced_producer_stats() TO service_role;

COMMIT;
