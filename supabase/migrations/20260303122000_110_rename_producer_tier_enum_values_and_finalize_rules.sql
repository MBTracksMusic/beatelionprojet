/*
  # Finalize producer tier labels and tier-aware helpers

  Safer Postgres strategy used here:
  - rename enum values in place instead of rebuilding the enum type
  - preserves dependencies on views, functions and policies
  - removes the live labels `starter` / `pro` from the schema contract

  Final labels:
  - `user`
  - `producteur`
  - `elite`
*/

BEGIN;

DO $$
DECLARE
  v_has_starter boolean := false;
  v_has_user boolean := false;
  v_has_pro boolean := false;
  v_has_producteur boolean := false;
BEGIN
  IF to_regtype('public.producer_tier_type') IS NULL THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'producer_tier_type'
      AND e.enumlabel = 'starter'
  ) INTO v_has_starter;

  SELECT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'producer_tier_type'
      AND e.enumlabel = 'user'
  ) INTO v_has_user;

  SELECT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'producer_tier_type'
      AND e.enumlabel = 'pro'
  ) INTO v_has_pro;

  SELECT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typname = 'producer_tier_type'
      AND e.enumlabel = 'producteur'
  ) INTO v_has_producteur;

  IF v_has_starter AND v_has_user THEN
    RAISE EXCEPTION 'producer_tier_type contains both starter and user; aborting enum rename';
  ELSIF v_has_starter THEN
    ALTER TYPE public.producer_tier_type RENAME VALUE 'starter' TO 'user';
  END IF;

  IF v_has_pro AND v_has_producteur THEN
    RAISE EXCEPTION 'producer_tier_type contains both pro and producteur; aborting enum rename';
  ELSIF v_has_pro THEN
    ALTER TYPE public.producer_tier_type RENAME VALUE 'pro' TO 'producteur';
  END IF;
END $$;

ALTER TABLE public.user_profiles
ALTER COLUMN producer_tier SET DEFAULT 'user'::public.producer_tier_type;

CREATE OR REPLACE FUNCTION public.producer_tier_rank(p_tier public.producer_tier_type)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'user'::public.producer_tier_type THEN 0
    WHEN 'producteur'::public.producer_tier_type THEN 1
    WHEN 'elite'::public.producer_tier_type THEN 2
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

  IF NOT public.has_producer_tier(v_uid, 'producteur'::public.producer_tier_type) THEN
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
