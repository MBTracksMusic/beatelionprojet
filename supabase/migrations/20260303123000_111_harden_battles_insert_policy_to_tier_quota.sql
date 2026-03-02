/*
  # Harden battles INSERT RLS with explicit tier + monthly quota

  Objective:
  - Make battle creation depend on `user_profiles.producer_tier`, not on legacy
    starter/pro assumptions.
  - Allow creation only for tiers explicitly authorized by business rules:
      - `producteur`
      - `elite` (future-ready)
  - Keep plan lookup in `public.producer_plans` as source of truth.
  - Fail closed on missing tier / missing plan / invalid actor.

  Important:
  - This migration assumes producer tiers have already been normalized to the
    live labels `user` / `producteur` / `elite`.
  - If legacy `pro` values still exist, `can_create_battle()` will refuse them
    by design until the tier cleanup migration is applied.

  SQL tests to run after deployment (service_role or the same authenticated user):

  1) Free user => false
     -- UPDATE public.user_profiles
     -- SET producer_tier = 'user'::public.producer_tier_type
     -- WHERE id = '<uid>';
     -- SELECT public.can_create_battle('<uid>'::uuid);

  2) Producteur with 0 battle this month => true
     -- UPDATE public.user_profiles
     -- SET producer_tier = 'producteur'::public.producer_tier_type
     -- WHERE id = '<uid>';
     -- DELETE FROM public.battles
     -- WHERE producer1_id = '<uid>'::uuid
     --   AND created_at >= date_trunc('month', now())
     --   AND created_at < date_trunc('month', now()) + interval '1 month';
     -- SELECT public.can_create_battle('<uid>'::uuid);

  3) Producteur with 3+ battles this month => false
     -- UPDATE public.user_profiles
     -- SET producer_tier = 'producteur'::public.producer_tier_type
     -- WHERE id = '<uid>';
     -- -- ensure producer_plans.producteur.max_battles_created_per_month = 3
     -- SELECT public.can_create_battle('<uid>'::uuid);
*/

BEGIN;

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

  IF v_tier_text NOT IN ('producteur', 'elite') THEN
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

DROP POLICY IF EXISTS "Active producers can create battles" ON public.battles;

CREATE POLICY "Active producers can create battles"
  ON public.battles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND producer1_id = auth.uid()
    AND producer2_id IS NOT NULL
    AND producer1_id != producer2_id
    AND status = 'pending_acceptance'
    AND winner_id IS NULL
    AND votes_producer1 = 0
    AND votes_producer2 = 0
    AND accepted_at IS NULL
    AND rejected_at IS NULL
    AND admin_validated_at IS NULL
    AND public.can_create_battle(auth.uid()) = true
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up2
      WHERE up2.id = producer2_id
        AND up2.is_producer_active = true
    )
    AND (
      product1_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM public.products p1
        WHERE p1.id = product1_id
          AND p1.producer_id = auth.uid()
          AND p1.deleted_at IS NULL
      )
    )
    AND (
      product2_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM public.products p2
        WHERE p2.id = product2_id
          AND p2.producer_id = producer2_id
          AND p2.deleted_at IS NULL
      )
    )
  );

COMMIT;
