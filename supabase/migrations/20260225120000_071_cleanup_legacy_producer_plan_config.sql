/*
  # Cleanup legacy producer_plan_config and enforce producer_plans as source of truth

  Goals:
  - Ensure STARTER / PRO / ELITE tiers exist in public.producer_plans.
  - Align PRO Stripe price id with the active configured price.
  - Remove public-read dependency on legacy public.producer_plan_config.
*/

BEGIN;

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
  ('pro'::public.producer_tier_type, NULL, NULL, 0.0500, 'price_1T3hL6EDvdPqljdSA7xHzSh2', true),
  ('elite'::public.producer_tier_type, NULL, NULL, 0.0300, NULL, true)
ON CONFLICT (tier) DO NOTHING;

UPDATE public.producer_plans
SET
  stripe_price_id = 'price_1T3hL6EDvdPqljdSA7xHzSh2',
  updated_at = now()
WHERE tier = 'pro'::public.producer_tier_type;

DO $$
BEGIN
  IF to_regclass('public.producer_plan_config') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS "Producer plan readable" ON public.producer_plan_config';
    EXECUTE 'REVOKE ALL ON TABLE public.producer_plan_config FROM anon';
    EXECUTE 'REVOKE ALL ON TABLE public.producer_plan_config FROM authenticated';
    EXECUTE 'COMMENT ON TABLE public.producer_plan_config IS ''DEPRECATED: legacy single-plan table. Use public.producer_plans.''';
  END IF;
END
$$;

COMMIT;
