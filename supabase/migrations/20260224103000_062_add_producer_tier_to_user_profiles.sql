/*
  # Add producer_tier axis to user_profiles (safe step 1)

  Scope:
  - Create enum `public.producer_tier_type` with values: starter, pro, elite.
  - Add `public.user_profiles.producer_tier` column.
  - Backfill current active producers to `pro`, others to `starter`.
  - Keep existing subscription model untouched (`is_producer_active`, Stripe, webhooks, RLS).
*/

BEGIN;

-- 1) Create enum if it does not already exist
DO $$
BEGIN
  CREATE TYPE public.producer_tier_type AS ENUM ('starter', 'pro', 'elite');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

-- 2) Add column if missing (no impact on existing access logic)
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS producer_tier public.producer_tier_type;

-- 3) Enforce default for new rows
ALTER TABLE public.user_profiles
  ALTER COLUMN producer_tier SET DEFAULT 'starter'::public.producer_tier_type;

-- 4) Normalize nulls first (legacy rows / partial runs)
UPDATE public.user_profiles
SET producer_tier = 'starter'::public.producer_tier_type
WHERE producer_tier IS NULL;

-- 5) Backfill active producers to pro (existing business behavior preserved)
UPDATE public.user_profiles
SET producer_tier = 'pro'::public.producer_tier_type
WHERE is_producer_active = true
  AND producer_tier = 'starter'::public.producer_tier_type;

-- 6) Enforce NOT NULL after backfill
ALTER TABLE public.user_profiles
  ALTER COLUMN producer_tier SET NOT NULL;

COMMIT;
