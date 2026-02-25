/*
  # Harden ELITE interest dedupe

  - Enforce case-insensitive uniqueness on email.
  - Keeps existing table and policies unchanged.
*/

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS elite_interest_email_unique
ON public.elite_interest (lower(email));

COMMIT;
