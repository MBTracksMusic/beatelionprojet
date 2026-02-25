/*
  # Drop legacy elite_waitlist table

  Keep `public.elite_interest` as the single source of truth for ELITE launch interest.
*/

BEGIN;

DROP TABLE IF EXISTS public.elite_waitlist CASCADE;

COMMIT;
