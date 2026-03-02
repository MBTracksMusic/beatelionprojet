/*
  # Add battles quota status RPC and elite cap

  Goals:
  - Ensure `producer_plans` contains battle caps for:
      - `producteur` => 3 / month
      - `elite` => 10 / month
  - Keep `public.can_create_battle()` fail-closed and tier-aware.
  - Expose a safe per-user quota RPC for the frontend:
      `public.get_battles_quota_status()`

  Security model:
  - Allowed creation tiers are explicitly allowlisted: `producteur`, `elite`
  - Plan lookup stays dynamic through `public.producer_plans`
  - Missing tier / missing plan / inactive plan => deny
*/

BEGIN;

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_producteur_amount_cents integer := NULL;
  v_elite_price_id text := NULL;
  v_elite_amount_cents integer := NULL;
BEGIN
  IF to_regclass('public.producer_plans') IS NULL THEN
    RETURN;
  END IF;

  SELECT
    pp.stripe_price_id,
    pp.amount_cents
  INTO
    v_producteur_price_id,
    v_producteur_amount_cents
  FROM public.producer_plans pp
  WHERE pp.tier::text = 'producteur'
  LIMIT 1;

  SELECT
    pp.stripe_price_id,
    pp.amount_cents
  INTO
    v_elite_price_id,
    v_elite_amount_cents
  FROM public.producer_plans pp
  WHERE pp.tier::text = 'elite'
  LIMIT 1;

  INSERT INTO public.producer_plans (
    tier,
    max_beats_published,
    max_battles_created_per_month,
    commission_rate,
    stripe_price_id,
    is_active,
    amount_cents
  )
  VALUES
    (
      'producteur'::public.producer_tier_type,
      NULL,
      3,
      0.0500,
      v_producteur_price_id,
      true,
      v_producteur_amount_cents
    ),
    (
      'elite'::public.producer_tier_type,
      NULL,
      10,
      0.0300,
      v_elite_price_id,
      true,
      v_elite_amount_cents
    )
  ON CONFLICT (tier) DO UPDATE
  SET
    max_battles_created_per_month = EXCLUDED.max_battles_created_per_month,
    commission_rate = EXCLUDED.commission_rate,
    stripe_price_id = COALESCE(EXCLUDED.stripe_price_id, public.producer_plans.stripe_price_id),
    is_active = true,
    amount_cents = COALESCE(EXCLUDED.amount_cents, public.producer_plans.amount_cents),
    updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION public.can_create_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_tier_text text := 'user';
  v_allowed_tiers text[] := ARRAY['producteur', 'elite'];
  v_max_battles integer;
  v_count bigint := 0;
  v_month_start timestamptz := date_trunc('month', now());
  v_next_month_start timestamptz := date_trunc('month', now()) + interval '1 month';
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
  ) THEN
    RETURN false;
  END IF;

  SELECT COALESCE(up.producer_tier::text, 'user')
  INTO v_tier_text
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF NOT (v_tier_text = ANY (v_allowed_tiers)) THEN
    RETURN false;
  END IF;

  SELECT pp.max_battles_created_per_month
  INTO v_max_battles
  FROM public.producer_plans pp
  WHERE pp.tier::text = v_tier_text
    AND pp.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_max_battles IS NULL THEN
    RETURN true;
  END IF;

  SELECT count(*)
  INTO v_count
  FROM public.battles b
  WHERE b.producer1_id = p_user_id
    AND b.created_at >= v_month_start
    AND b.created_at < v_next_month_start;

  RETURN v_count < v_max_battles;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.can_create_battle(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_create_battle(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_create_battle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_create_battle(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.get_battles_quota_status()
RETURNS TABLE (
  tier text,
  used_this_month bigint,
  max_per_month integer,
  can_create boolean,
  reset_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tier_text text := 'user';
  v_allowed_tiers text[] := ARRAY['producteur', 'elite'];
  v_used bigint := 0;
  v_max integer := NULL;
  v_can_create boolean := false;
  v_month_start timestamptz := date_trunc('month', now());
  v_next_month_start timestamptz := date_trunc('month', now()) + interval '1 month';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(up.producer_tier::text, 'user')
  INTO v_tier_text
  FROM public.user_profiles up
  WHERE up.id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)
  INTO v_used
  FROM public.battles b
  WHERE b.producer1_id = v_uid
    AND b.created_at >= v_month_start
    AND b.created_at < v_next_month_start;

  IF v_tier_text = ANY (v_allowed_tiers) THEN
    SELECT pp.max_battles_created_per_month
    INTO v_max
    FROM public.producer_plans pp
    WHERE pp.tier::text = v_tier_text
      AND pp.is_active = true
    LIMIT 1;
  ELSE
    v_max := 0;
  END IF;

  IF v_tier_text = ANY (v_allowed_tiers) AND v_max IS NOT NULL THEN
    v_can_create := v_used < v_max;
  ELSE
    v_can_create := false;
  END IF;

  RETURN QUERY
  SELECT
    v_tier_text,
    v_used,
    v_max,
    v_can_create,
    v_next_month_start;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_battles_quota_status() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_battles_quota_status() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_battles_quota_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_battles_quota_status() TO service_role;

COMMIT;
