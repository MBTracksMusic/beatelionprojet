-- Producer Stripe pricing configuration
-- Stripe price IDs must come from environment/Vault secrets.
-- Do not hardcode Stripe price IDs in migrations.
-- Stripe Dashboard -> Product catalog -> Product -> Pricing -> Price ID
-- Example format: price_1QXabc123XYZ

DO $$
DECLARE
  v_producteur_price_id text := NULL;
  v_elite_price_id text := NULL;
BEGIN
  -- Optional runtime-injected settings (if provided by migration tooling).
  v_producteur_price_id := NULLIF(btrim(current_setting('app.stripe_price_producer', true)), '');
  v_elite_price_id := NULLIF(btrim(current_setting('app.stripe_price_elite', true)), '');

  -- Supabase Vault fallback.
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

  -- Remove legacy invalid values (including placeholder-like values).
  UPDATE producer_plans
  SET stripe_price_id = NULL
  WHERE tier IN ('producteur'::public.producer_tier_type, 'elite'::public.producer_tier_type)
    AND stripe_price_id IS NOT NULL
    AND stripe_price_id !~ '^price_[A-Za-z0-9]+$';

  -- Keep paid plans active.
  UPDATE producer_plans
  SET is_active = true
  WHERE tier IN ('producteur'::public.producer_tier_type, 'elite'::public.producer_tier_type);

  -- Apply configured producer price only when it looks like a real Stripe price id.
  IF v_producteur_price_id IS NOT NULL AND v_producteur_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE producer_plans
    SET stripe_price_id = v_producteur_price_id
    WHERE tier = 'producteur'::public.producer_tier_type
      AND stripe_price_id IS DISTINCT FROM v_producteur_price_id;
  END IF;

  -- Apply configured elite price only when it looks like a real Stripe price id.
  IF v_elite_price_id IS NOT NULL AND v_elite_price_id ~ '^price_[A-Za-z0-9]+$' THEN
    UPDATE producer_plans
    SET stripe_price_id = v_elite_price_id
    WHERE tier = 'elite'::public.producer_tier_type
      AND stripe_price_id IS DISTINCT FROM v_elite_price_id;
  END IF;
END
$$;

-- Recreate to keep migration reruns safe in non-prod environments.
ALTER TABLE producer_plans
DROP CONSTRAINT IF EXISTS producer_plans_price_not_null;

ALTER TABLE producer_plans
DROP CONSTRAINT IF EXISTS producer_plans_price_valid_format;

ALTER TABLE producer_plans
ADD CONSTRAINT producer_plans_price_valid_format
CHECK (
  tier = 'user'::public.producer_tier_type
  OR stripe_price_id IS NULL
  OR stripe_price_id ~ '^price_[A-Za-z0-9]+$'
);

COMMENT ON CONSTRAINT producer_plans_price_valid_format ON producer_plans IS
'Stripe price IDs must come from environment or Vault secrets (Stripe Dashboard -> Product catalog -> Product -> Pricing -> Price ID).';
