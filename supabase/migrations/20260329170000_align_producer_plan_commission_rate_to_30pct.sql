/*
  # Align producer plan commission rates to the current marketplace rule

  Business rule:
  - Platform commission is fixed at 30%
  - Producer payout is fixed at 70%

  Why:
  - The checkout flow now enforces a 30/70 split for all sales.
  - Historical producer_plans rows still carried older commission_rate values.
  - Normalizing producer_plans avoids stale or contradictory plan metadata.
*/

BEGIN;

UPDATE public.producer_plans
SET
  commission_rate = 0.3000,
  updated_at = now()
WHERE commission_rate IS DISTINCT FROM 0.3000;

COMMIT;
