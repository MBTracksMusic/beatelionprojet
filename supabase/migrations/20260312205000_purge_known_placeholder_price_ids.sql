/*
  # Purge known placeholder Stripe price ids from producer_plans

  Why:
  - Placeholder values such as price_XXXXXXXX can pass a generic format check
    but are not real Stripe price ids.
*/

BEGIN;

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_elite_price_id text := NULL;
  v_placeholder_ids text[] := ARRAY[
    'price_xxxxxxxx',
    'price_yyyyyyyy',
    'price_producer_monthly',
    'price_elite_monthly',
    'price_xxx',
    'price_replace_me'
  ];
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

  -- Legacy fallback: use single-plan config when still present.
  IF v_producteur_price_id IS NULL AND to_regclass('public.producer_plan_config') IS NOT NULL THEN
    SELECT NULLIF(btrim(stripe_price_id), '')
    INTO v_producteur_price_id
    FROM public.producer_plan_config
    WHERE id = true
    LIMIT 1;
  END IF;

  -- Ignore malformed/placeholder candidate values.
  IF v_producteur_price_id IS NOT NULL
     AND (v_producteur_price_id !~ '^price_[A-Za-z0-9]+$' OR lower(v_producteur_price_id) = ANY(v_placeholder_ids)) THEN
    v_producteur_price_id := NULL;
  END IF;

  IF v_elite_price_id IS NOT NULL
     AND (v_elite_price_id !~ '^price_[A-Za-z0-9]+$' OR lower(v_elite_price_id) = ANY(v_placeholder_ids)) THEN
    v_elite_price_id := NULL;
  END IF;

  -- Replace placeholders only when a valid replacement exists.
  IF v_producteur_price_id IS NOT NULL AND v_producteur_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE public.producer_plans
    SET stripe_price_id = v_producteur_price_id,
        updated_at = now()
    WHERE tier = 'producteur'::public.producer_tier_type
      AND (
        lower(coalesce(stripe_price_id, '')) = ANY(v_placeholder_ids)
        OR stripe_price_id IS DISTINCT FROM v_producteur_price_id
      );
  END IF;

  IF v_elite_price_id IS NOT NULL AND v_elite_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE public.producer_plans
    SET stripe_price_id = v_elite_price_id,
        updated_at = now()
    WHERE tier = 'elite'::public.producer_tier_type
      AND (
        lower(coalesce(stripe_price_id, '')) = ANY(v_placeholder_ids)
        OR stripe_price_id IS DISTINCT FROM v_elite_price_id
      );
  END IF;
END
$$;

COMMIT;
