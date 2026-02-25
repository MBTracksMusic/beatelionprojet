/*
  # Enforce battles quota and prevent created_at backdating

  Starter quota:
  - max_battles_created_per_month from `public.producer_plans`
  - counted battles: producer1_id = actor and created_at in current calendar month
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.can_create_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tier public.producer_tier_type;
  v_max_battles integer;
  v_count bigint := 0;
  v_month_start timestamptz := date_trunc('month', now());
  v_next_month_start timestamptz := date_trunc('month', now()) + interval '1 month';
BEGIN
  v_tier := public.get_producer_tier(p_user_id);
  IF v_tier IS NULL THEN
    RETURN false;
  END IF;

  SELECT limits.max_battles_created_per_month
  INTO v_max_battles
  FROM public.get_plan_limits(v_tier) AS limits;

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

CREATE INDEX IF NOT EXISTS idx_battles_producer1_created_month
  ON public.battles (producer1_id, created_at DESC);

DROP POLICY IF EXISTS "Active producers can create battles" ON public.battles;
CREATE POLICY "Active producers can create battles"
  ON public.battles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    producer1_id = auth.uid()
    AND producer2_id IS NOT NULL
    AND producer1_id != producer2_id
    AND status = 'pending_acceptance'
    AND winner_id IS NULL
    AND votes_producer1 = 0
    AND votes_producer2 = 0
    AND accepted_at IS NULL
    AND rejected_at IS NULL
    AND admin_validated_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND public.can_create_battle(auth.uid())
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

CREATE OR REPLACE FUNCTION public.battles_force_created_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.created_at := now();
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.battles_lock_created_at_on_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.created_at := OLD.created_at;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_battles_force_created_at ON public.battles;
DROP TRIGGER IF EXISTS trg_battles_lock_created_at_on_update ON public.battles;

CREATE TRIGGER trg_battles_force_created_at
BEFORE INSERT ON public.battles
FOR EACH ROW
EXECUTE FUNCTION public.battles_force_created_at();

CREATE TRIGGER trg_battles_lock_created_at_on_update
BEFORE UPDATE ON public.battles
FOR EACH ROW
EXECUTE FUNCTION public.battles_lock_created_at_on_update();

COMMIT;
