/*
  # Harden GA4 purchase tracking idempotency

  - Adds a persistent delivery status to ga4_tracked_purchases
  - Keeps duplicate protection while avoiding delete-on-failure patterns
*/

BEGIN;

ALTER TABLE public.ga4_tracked_purchases
ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';

COMMIT;
