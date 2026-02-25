/*
  # Add amount_cents to producer_plans (single source of truth for displayed pricing)

  - Adds `amount_cents` to store UI checkout pricing per tier.
  - Seeds stable values:
    - starter: 0
    - pro: 1999
    - elite: NULL (coming soon)
*/

BEGIN;

ALTER TABLE public.producer_plans
ADD COLUMN IF NOT EXISTS amount_cents integer NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'producer_plans_amount_cents_non_negative'
      AND conrelid = 'public.producer_plans'::regclass
  ) THEN
    ALTER TABLE public.producer_plans
    ADD CONSTRAINT producer_plans_amount_cents_non_negative
    CHECK (amount_cents IS NULL OR amount_cents >= 0);
  END IF;
END
$$;

UPDATE public.producer_plans
SET amount_cents = CASE tier
  WHEN 'starter'::public.producer_tier_type THEN 0
  WHEN 'pro'::public.producer_tier_type THEN 1999
  WHEN 'elite'::public.producer_tier_type THEN NULL
  ELSE amount_cents
END,
updated_at = now()
WHERE tier IN (
  'starter'::public.producer_tier_type,
  'pro'::public.producer_tier_type,
  'elite'::public.producer_tier_type
);

COMMIT;
