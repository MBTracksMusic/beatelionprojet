/*
  # Normalize battle quota limits and expose per-user quota RPC

  Goals:
  - Add `producer_plans.battle_limit` as the explicit backend source of truth.
  - Enforce 5 battles/month for `producteur`.
  - Remove implicit unlimited behavior from nullable battle caps.
  - Expose `public.get_user_battle_quota(p_user_id)` for the frontend.
  - Prevent matchmaking suggestions when battle creation is not allowed.
*/

BEGIN;

ALTER TABLE public.producer_plans
  ADD COLUMN IF NOT EXISTS battle_limit integer;

COMMENT ON COLUMN public.producer_plans.battle_limit IS
  'Monthly battle creation limit. Use -1 for explicit unlimited access, 0 for no access.';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.producer_plans'::regclass
      AND conname = 'producer_plans_battle_limit_check'
  ) THEN
    ALTER TABLE public.producer_plans
    DROP CONSTRAINT producer_plans_battle_limit_check;
  END IF;

  ALTER TABLE public.producer_plans
  ADD CONSTRAINT producer_plans_battle_limit_check
  CHECK (
    battle_limit IS NULL
    OR battle_limit = -1
    OR battle_limit >= 0
  ) NOT VALID;
END $$;

ALTER TABLE public.producer_plans
VALIDATE CONSTRAINT producer_plans_battle_limit_check;

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_elite_price_id text := NULL;
BEGIN
  IF to_regclass('public.producer_plans') IS NULL THEN
    RETURN;
  END IF;

  SELECT pp.stripe_price_id
  INTO v_producteur_price_id
  FROM public.producer_plans pp
  WHERE pp.tier::text = 'producteur'
  LIMIT 1;

  SELECT pp.stripe_price_id
  INTO v_elite_price_id
  FROM public.producer_plans pp
  WHERE pp.tier::text = 'elite'
  LIMIT 1;

  INSERT INTO public.producer_plans (
    tier,
    max_beats_published,
    max_battles_created_per_month,
    battle_limit,
    commission_rate,
    stripe_price_id,
    is_active,
    amount_cents
  )
  VALUES
    (
      'user'::public.producer_tier_type,
      0,
      0,
      0,
      0.1200,
      NULL,
      true,
      0
    ),
    (
      'producteur'::public.producer_tier_type,
      NULL,
      5,
      5,
      0.0500,
      v_producteur_price_id,
      true,
      1999
    ),
    (
      'elite'::public.producer_tier_type,
      NULL,
      10,
      10,
      0.0300,
      v_elite_price_id,
      true,
      2999
    )
  ON CONFLICT (tier) DO UPDATE
  SET
    max_beats_published = EXCLUDED.max_beats_published,
    max_battles_created_per_month = EXCLUDED.max_battles_created_per_month,
    battle_limit = EXCLUDED.battle_limit,
    commission_rate = EXCLUDED.commission_rate,
    stripe_price_id = COALESCE(EXCLUDED.stripe_price_id, public.producer_plans.stripe_price_id),
    is_active = true,
    amount_cents = COALESCE(EXCLUDED.amount_cents, public.producer_plans.amount_cents),
    updated_at = now();
END $$;

UPDATE public.producer_plans
SET battle_limit = CASE
  WHEN tier::text = 'user' THEN 0
  WHEN tier::text = 'producteur' THEN 5
  WHEN tier::text = 'elite' THEN 10
  ELSE COALESCE(max_battles_created_per_month, 0)
END
WHERE battle_limit IS NULL;

CREATE OR REPLACE FUNCTION public.get_user_battle_quota(p_user_id uuid)
RETURNS TABLE (
  tier text,
  used_this_month bigint,
  battle_limit integer,
  remaining_this_month integer,
  can_create boolean,
  reason text,
  reset_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_tier_text text := 'user';
  v_used bigint := 0;
  v_limit integer := 0;
  v_remaining integer := 0;
  v_can_create boolean := false;
  v_reason text := 'plan_insufficient';
  v_month_start timestamptz := date_trunc('month', now());
  v_next_month_start timestamptz := date_trunc('month', now()) + interval '1 month';
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
    OR public.is_admin(v_actor)
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(up.producer_tier::text, 'user')
  INTO v_tier_text
  FROM public.user_profiles up
  WHERE up.id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)
  INTO v_used
  FROM public.battles b
  WHERE b.producer1_id = p_user_id
    AND b.created_at >= v_month_start
    AND b.created_at < v_next_month_start;

  SELECT COALESCE(pp.battle_limit, pp.max_battles_created_per_month, 0)
  INTO v_limit
  FROM public.producer_plans pp
  WHERE pp.tier::text = v_tier_text
    AND pp.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    v_limit := 0;
  END IF;

  IF v_limit = -1 THEN
    v_remaining := -1;
    v_can_create := true;
    v_reason := 'eligible';
  ELSIF v_limit <= 0 THEN
    v_remaining := 0;
    v_can_create := false;
    v_reason := 'plan_insufficient';
  ELSIF v_used >= v_limit THEN
    v_remaining := 0;
    v_can_create := false;
    v_reason := 'quota_reached';
  ELSE
    v_remaining := GREATEST(v_limit - v_used, 0)::integer;
    v_can_create := true;
    v_reason := 'eligible';
  END IF;

  RETURN QUERY
  SELECT
    v_tier_text,
    v_used,
    v_limit,
    v_remaining,
    v_can_create,
    v_reason,
    v_next_month_start;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_user_battle_quota(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_user_battle_quota(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_user_battle_quota(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_battle_quota(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.can_create_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_can_create boolean := false;
BEGIN
  SELECT quota.can_create
  INTO v_can_create
  FROM public.get_user_battle_quota(p_user_id) AS quota
  LIMIT 1;

  RETURN COALESCE(v_can_create, false);
EXCEPTION
  WHEN OTHERS THEN
    RETURN false;
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    quota.tier,
    quota.used_this_month,
    quota.battle_limit AS max_per_month,
    quota.can_create,
    quota.reset_at
  FROM public.get_user_battle_quota(v_uid) AS quota;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_battles_quota_status() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_battles_quota_status() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_battles_quota_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_battles_quota_status() TO service_role;

CREATE OR REPLACE FUNCTION public.suggest_opponents(p_user_id uuid)
RETURNS TABLE (
  user_id uuid,
  username text,
  avatar_url text,
  producer_tier public.producer_tier_type,
  elo_rating integer,
  battle_wins integer,
  battle_losses integer,
  battle_draws integer,
  elo_diff integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_user_rating integer := 1200;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
    OR public.is_admin(v_actor)
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF NOT public.can_create_battle(p_user_id) THEN
    RETURN;
  END IF;

  SELECT COALESCE(up.elo_rating, 1200)
  INTO v_user_rating
  FROM public.user_profiles up
  WHERE up.id = p_user_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    COALESCE(up.elo_rating, 1200) AS elo_rating,
    COALESCE(up.battle_wins, 0) AS battle_wins,
    COALESCE(up.battle_losses, 0) AS battle_losses,
    COALESCE(up.battle_draws, 0) AS battle_draws,
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer AS elo_diff
  FROM public.user_profiles up
  WHERE up.id <> p_user_id
    AND up.is_producer_active = true
    AND up.role = 'producer'
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 400
  ORDER BY
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC,
    up.username ASC NULLS LAST
  LIMIT 10;

  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    COALESCE(up.elo_rating, 1200) AS elo_rating,
    COALESCE(up.battle_wins, 0) AS battle_wins,
    COALESCE(up.battle_losses, 0) AS battle_losses,
    COALESCE(up.battle_draws, 0) AS battle_draws,
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer AS elo_diff
  FROM public.user_profiles up
  WHERE up.id <> p_user_id
    AND up.is_producer_active = true
    AND up.role = 'producer'
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 600
  ORDER BY
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC,
    up.username ASC NULLS LAST
  LIMIT 10;

  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    COALESCE(up.elo_rating, 1200) AS elo_rating,
    COALESCE(up.battle_wins, 0) AS battle_wins,
    COALESCE(up.battle_losses, 0) AS battle_losses,
    COALESCE(up.battle_draws, 0) AS battle_draws,
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer AS elo_diff
  FROM public.user_profiles up
  WHERE up.id <> p_user_id
    AND up.is_producer_active = true
    AND up.role = 'producer'
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 800
  ORDER BY
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC,
    up.username ASC NULLS LAST
  LIMIT 10;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.suggest_opponents(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.suggest_opponents(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.suggest_opponents(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggest_opponents(uuid) TO service_role;

COMMIT;
