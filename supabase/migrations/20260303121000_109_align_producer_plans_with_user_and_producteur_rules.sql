/*
  # Align producer_plans with future user/producteur semantics

  Target business rules after final enum rename:
  - starter -> future `user`: no battle creation
  - pro -> future `producteur`: 3 battles / month
  - elite: kept available, currently unlimited for battles

  This migration intentionally updates the legacy rows first.
  A later migration renames enum values:
  - `starter` => `user`
  - `pro` => `producteur`

  Idempotent and safe:
  - relaxes legacy positive-only constraints to allow zero for the free plan
  - upserts the 3 canonical rows
*/

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.producer_plans') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.producer_plans'::regclass
      AND conname = 'producer_plans_max_beats_published_check'
  ) THEN
    ALTER TABLE public.producer_plans
    DROP CONSTRAINT producer_plans_max_beats_published_check;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.producer_plans'::regclass
      AND conname = 'producer_plans_max_battles_created_per_month_check'
  ) THEN
    ALTER TABLE public.producer_plans
    DROP CONSTRAINT producer_plans_max_battles_created_per_month_check;
  END IF;

  ALTER TABLE public.producer_plans
  ADD CONSTRAINT producer_plans_max_beats_published_check
  CHECK (
    max_beats_published IS NULL
    OR max_beats_published >= 0
  ) NOT VALID;

  ALTER TABLE public.producer_plans
  ADD CONSTRAINT producer_plans_max_battles_created_per_month_check
  CHECK (
    max_battles_created_per_month IS NULL
    OR max_battles_created_per_month >= 0
  ) NOT VALID;
END $$;

ALTER TABLE public.producer_plans
VALIDATE CONSTRAINT producer_plans_max_beats_published_check;

ALTER TABLE public.producer_plans
VALIDATE CONSTRAINT producer_plans_max_battles_created_per_month_check;

DO $$
DECLARE
  v_pro_price_id text := NULL;
  v_pro_amount_cents integer := 1999;
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
    v_pro_price_id,
    v_pro_amount_cents
  FROM public.producer_plans pp
  WHERE pp.tier = 'pro'::public.producer_tier_type
  LIMIT 1;

  SELECT
    pp.stripe_price_id,
    pp.amount_cents
  INTO
    v_elite_price_id,
    v_elite_amount_cents
  FROM public.producer_plans pp
  WHERE pp.tier = 'elite'::public.producer_tier_type
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
      'starter'::public.producer_tier_type,
      0,
      0,
      0.1200,
      NULL,
      true,
      0
    ),
    (
      'pro'::public.producer_tier_type,
      NULL,
      3,
      0.0500,
      v_pro_price_id,
      true,
      COALESCE(v_pro_amount_cents, 1999)
    ),
    (
      'elite'::public.producer_tier_type,
      NULL,
      NULL,
      0.0300,
      v_elite_price_id,
      true,
      v_elite_amount_cents
    )
  ON CONFLICT (tier) DO UPDATE
  SET
    max_beats_published = EXCLUDED.max_beats_published,
    max_battles_created_per_month = EXCLUDED.max_battles_created_per_month,
    commission_rate = EXCLUDED.commission_rate,
    stripe_price_id = CASE
      WHEN EXCLUDED.tier = 'starter'::public.producer_tier_type THEN NULL
      ELSE COALESCE(EXCLUDED.stripe_price_id, public.producer_plans.stripe_price_id)
    END,
    is_active = true,
    amount_cents = CASE
      WHEN EXCLUDED.tier = 'starter'::public.producer_tier_type THEN 0
      ELSE COALESCE(EXCLUDED.amount_cents, public.producer_plans.amount_cents)
    END,
    updated_at = now();
END $$;

COMMIT;
