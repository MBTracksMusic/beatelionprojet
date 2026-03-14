/*
  # Fix invalid producer Stripe price placeholders

  Why:
  - Some environments still contain placeholder values in public.producer_plans.stripe_price_id
    such as price_XXXXXXXX / price_YYYYYYYY.
  - producer-checkout prioritizes DB price_id, so invalid placeholders break Stripe checkout.

  What:
  - Load producer/elite Stripe price ids from app settings or Vault when available.
  - Remove invalid non-Stripe-format price ids from paid tiers.
  - Backfill valid price ids when secrets are available.
  - Keep idempotent behavior.
*/

BEGIN;

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_elite_price_id text := NULL;
BEGIN
  v_producteur_price_id := NULLIF(btrim(current_setting('app.stripe_price_producer', true)), '');
  v_elite_price_id := NULLIF(btrim(current_setting('app.stripe_price_elite', true)), '');

  IF to_regnamespace('vault') IS NOT NULL THEN
    IF v_producteur_price_id IS NULL THEN
      SELECT NULLIF(btrim(decrypted_secret), '')
      INTO v_producteur_price_id
      FROM vault.decrypted_secrets
      WHERE lower(name) IN ('stripe_producer_price_id', 'stripe_price_producer')
      ORDER BY CASE WHEN lower(name) = 'stripe_producer_price_id' THEN 0 ELSE 1 END
      LIMIT 1;
    END IF;

    IF v_elite_price_id IS NULL THEN
      SELECT NULLIF(btrim(decrypted_secret), '')
      INTO v_elite_price_id
      FROM vault.decrypted_secrets
      WHERE lower(name) = 'stripe_producer_elite_price_id'
      LIMIT 1;
    END IF;
  END IF;

  -- Remove invalid placeholders and malformed values from paid tiers.
  UPDATE public.producer_plans
  SET stripe_price_id = NULL,
      updated_at = now()
  WHERE tier IN ('producteur'::public.producer_tier_type, 'elite'::public.producer_tier_type)
    AND stripe_price_id IS NOT NULL
    AND stripe_price_id !~ '^price_[A-Za-z0-9]+$';

  IF v_producteur_price_id IS NOT NULL AND v_producteur_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE public.producer_plans
    SET stripe_price_id = v_producteur_price_id,
        updated_at = now()
    WHERE tier = 'producteur'::public.producer_tier_type
      AND stripe_price_id IS DISTINCT FROM v_producteur_price_id;
  END IF;

  IF v_elite_price_id IS NOT NULL AND v_elite_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE public.producer_plans
    SET stripe_price_id = v_elite_price_id,
        updated_at = now()
    WHERE tier = 'elite'::public.producer_tier_type
      AND stripe_price_id IS DISTINCT FROM v_elite_price_id;
  END IF;
END
$$;

COMMIT;
