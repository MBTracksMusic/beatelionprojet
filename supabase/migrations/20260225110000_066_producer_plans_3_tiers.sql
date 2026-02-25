/*
  # Producer plans (3 tiers) as backend source of truth

  Creates `public.producer_plans` and seeds STARTER / PRO / ELITE.
  This table is used by quota enforcement and Stripe tier mapping.
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.producer_plans (
  tier public.producer_tier_type PRIMARY KEY,
  max_beats_published integer NULL CHECK (max_beats_published IS NULL OR max_beats_published > 0),
  max_battles_created_per_month integer NULL CHECK (
    max_battles_created_per_month IS NULL
    OR max_battles_created_per_month > 0
  ),
  commission_rate numeric(5,4) NOT NULL CHECK (commission_rate >= 0 AND commission_rate <= 1),
  stripe_price_id text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_producer_plans_stripe_price_id
  ON public.producer_plans (stripe_price_id)
  WHERE stripe_price_id IS NOT NULL;

DO $$
BEGIN
  IF to_regproc('public.update_updated_at_column()') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS update_producer_plans_updated_at ON public.producer_plans;
    CREATE TRIGGER update_producer_plans_updated_at
      BEFORE UPDATE ON public.producer_plans
      FOR EACH ROW
      EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END
$$;

ALTER TABLE public.producer_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view active producer plans" ON public.producer_plans;
CREATE POLICY "Anyone can view active producer plans"
  ON public.producer_plans
  FOR SELECT
  USING (is_active = true);

GRANT SELECT ON TABLE public.producer_plans TO anon;
GRANT SELECT ON TABLE public.producer_plans TO authenticated;
GRANT SELECT ON TABLE public.producer_plans TO service_role;

DO $$
DECLARE
  v_pro_price_id text := NULL;
BEGIN
  IF to_regclass('public.producer_plan_config') IS NOT NULL THEN
    SELECT NULLIF(ppc.stripe_price_id, '')
    INTO v_pro_price_id
    FROM public.producer_plan_config ppc
    WHERE ppc.id = true
    LIMIT 1;
  END IF;

  INSERT INTO public.producer_plans (
    tier,
    max_beats_published,
    max_battles_created_per_month,
    commission_rate,
    stripe_price_id,
    is_active
  )
  VALUES
    ('starter'::public.producer_tier_type, 3, 1, 0.1200, NULL, true),
    ('pro'::public.producer_tier_type, NULL, NULL, 0.0500, v_pro_price_id, true),
    ('elite'::public.producer_tier_type, NULL, NULL, 0.0300, NULL, true)
  ON CONFLICT (tier) DO UPDATE
  SET
    max_beats_published = EXCLUDED.max_beats_published,
    max_battles_created_per_month = EXCLUDED.max_battles_created_per_month,
    commission_rate = EXCLUDED.commission_rate,
    stripe_price_id = COALESCE(EXCLUDED.stripe_price_id, public.producer_plans.stripe_price_id),
    is_active = EXCLUDED.is_active,
    updated_at = now();
END
$$;

COMMIT;
