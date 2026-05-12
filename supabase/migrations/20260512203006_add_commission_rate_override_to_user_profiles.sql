-- Add per-user commission rate override to user_profiles.
-- NULL = standard tier rate (30%); 0.0000 = 0% commission (lifetime/special users).
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS commission_rate_override NUMERIC(5,4) DEFAULT NULL;
