/*
  # Normalize legacy producer tiers before enum rename

  Goal:
  - Normalize legacy `starter` / `pro` rows against the current subscription truth.
  - Prepare a safe later rename to `user` / `producteur` without stale data.

  Rules applied:
  - active producer subscription => `pro`
  - otherwise => `starter`
  - `elite` is left untouched

  Notes:
  - Uses `public.producer_subscriptions` when present.
  - Falls back to `user_profiles.is_producer_active` if the subscription table is absent.
  - Idempotent: rerunning it only re-applies the same normalized state.
*/

BEGIN;

DO $$
DECLARE
  v_has_subscription_table boolean := to_regclass('public.producer_subscriptions') IS NOT NULL;
BEGIN
  IF to_regclass('public.user_profiles') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name = 'producer_tier'
  ) THEN
    RETURN;
  END IF;

  IF v_has_subscription_table THEN
    UPDATE public.user_profiles AS up
    SET
      producer_tier = CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.producer_subscriptions ps
          WHERE ps.user_id = up.id
            AND COALESCE(ps.is_producer_active, false) = true
            AND ps.subscription_status IN ('active', 'trialing')
            AND ps.current_period_end > now()
        ) THEN 'pro'::public.producer_tier_type
        ELSE 'starter'::public.producer_tier_type
      END,
      updated_at = now()
    WHERE up.producer_tier IN (
      'starter'::public.producer_tier_type,
      'pro'::public.producer_tier_type
    )
      AND up.producer_tier IS DISTINCT FROM CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.producer_subscriptions ps
          WHERE ps.user_id = up.id
            AND COALESCE(ps.is_producer_active, false) = true
            AND ps.subscription_status IN ('active', 'trialing')
            AND ps.current_period_end > now()
        ) THEN 'pro'::public.producer_tier_type
        ELSE 'starter'::public.producer_tier_type
      END;
  ELSE
    UPDATE public.user_profiles AS up
    SET
      producer_tier = CASE
        WHEN COALESCE(up.is_producer_active, false) = true
          THEN 'pro'::public.producer_tier_type
        ELSE 'starter'::public.producer_tier_type
      END,
      updated_at = now()
    WHERE up.producer_tier IN (
      'starter'::public.producer_tier_type,
      'pro'::public.producer_tier_type
    )
      AND up.producer_tier IS DISTINCT FROM CASE
        WHEN COALESCE(up.is_producer_active, false) = true
          THEN 'pro'::public.producer_tier_type
        ELSE 'starter'::public.producer_tier_type
      END;
  END IF;
END $$;

COMMIT;
