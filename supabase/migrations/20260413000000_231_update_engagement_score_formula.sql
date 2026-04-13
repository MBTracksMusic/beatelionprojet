/*
  # Update engagement score formula

  Old formula: completed*2 - refusals*1
  New formula: completed*2 + wins*3 - refusals*2 + draws*1

  Rationale:
  - wins*3 : valorise les victoires (différencie un dominant d'un simple participant)
  - refusals*2 : pénalise davantage les refus (signal négatif fort)
  - draws*1 : légèrement positif (battle terminée = engagement)
  - completed*2 : inchangé (participation de base)

  After updating the function, recalculates engagement for all existing profiles.
*/

BEGIN;

-- ── 1. Update recalculate_engagement() ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.recalculate_engagement(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_score integer;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  UPDATE public.user_profiles up
  SET engagement_score = (
      (COALESCE(up.battles_completed, 0) * 2)
    + (COALESCE(up.battle_wins,       0) * 3)
    - (COALESCE(up.battle_refusal_count, 0) * 2)
    + (COALESCE(up.battle_draws,      0) * 1)
  )
  WHERE up.id = p_user_id
  RETURNING up.engagement_score INTO v_score;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found';
  END IF;

  RETURN v_score;
END;
$$;

-- ── 2. Recalculate all existing profiles ────────────────────────────────────

DO $$
DECLARE
  v_user_id uuid;
  v_count   integer := 0;
BEGIN
  FOR v_user_id IN
    SELECT id FROM public.user_profiles
  LOOP
    BEGIN
      PERFORM public.recalculate_engagement(v_user_id);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        -- Skip profiles that raise unexpected errors (e.g. missing columns)
        NULL;
    END;
  END LOOP;

  RAISE NOTICE 'recalculate_engagement: updated % profiles', v_count;
END;
$$;

COMMIT;
