/*
  # Reseed producer plans from Vault-backed Stripe config

  Why:
  - The pricing CTA depends on active rows in `public.producer_plans`.
  - If rows are missing, frontend falls back to defaults and the producer CTA is disabled.

  What:
  - Upsert canonical tiers: user / producteur / elite.
  - Recover Stripe price ids from Vault secrets when available:
      - STRIPE_PRODUCER_PRICE_ID
      - STRIPE_PRODUCER_ELITE_PRICE_ID
  - Preserve any existing non-null stripe_price_id already stored in DB.
*/

BEGIN;

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_elite_price_id text := NULL;
BEGIN
  IF to_regclass('public.producer_plans') IS NULL THEN
    RAISE NOTICE 'Table public.producer_plans not found; skipping reseed.';
    RETURN;
  END IF;

  IF to_regnamespace('vault') IS NOT NULL THEN
    SELECT NULLIF(btrim(decrypted_secret), '')
    INTO v_producteur_price_id
    FROM vault.decrypted_secrets
    WHERE lower(name) = 'stripe_producer_price_id'
    LIMIT 1;

    SELECT NULLIF(btrim(decrypted_secret), '')
    INTO v_elite_price_id
    FROM vault.decrypted_secrets
    WHERE lower(name) = 'stripe_producer_elite_price_id'
    LIMIT 1;
  END IF;

  INSERT INTO public.producer_plans (
    tier,
    max_beats_published,
    max_battles_created_per_month,
    commission_rate,
    stripe_price_id,
    is_active,
    amount_cents
  )
  VALUES
    (
      'user'::public.producer_tier_type,
      0,
      0,
      0.1200,
      NULL,
      true,
      0
    ),
    (
      'producteur'::public.producer_tier_type,
      NULL,
      3,
      0.0500,
      v_producteur_price_id,
      true,
      1999
    ),
    (
      'elite'::public.producer_tier_type,
      NULL,
      10,
      0.0300,
      v_elite_price_id,
      true,
      2999
    )
  ON CONFLICT (tier) DO UPDATE
  SET
    max_beats_published = EXCLUDED.max_beats_published,
    max_battles_created_per_month = EXCLUDED.max_battles_created_per_month,
    commission_rate = EXCLUDED.commission_rate,
    stripe_price_id = COALESCE(EXCLUDED.stripe_price_id, public.producer_plans.stripe_price_id),
    is_active = true,
    amount_cents = COALESCE(EXCLUDED.amount_cents, public.producer_plans.amount_cents),
    updated_at = now();
END
$$;

COMMIT;
