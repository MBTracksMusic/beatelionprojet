/*
  # Harden credit purchase RPC

  Targets:
  - explicit business idempotency for credit purchases
  - deterministic license selection
  - externalized economics constants
  - clearer product availability guards
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Externalize V1 economics constants to app_settings
-- ---------------------------------------------------------------------------
INSERT INTO public.app_settings (key, value)
VALUES (
  'credit_purchase_economics',
  jsonb_build_object(
    'credit_cost_per_beat', 2,
    'credit_unit_value_cents', 666,
    'producer_share_bps', 6000,
    'platform_share_bps', 4000,
    'gross_reference_amount_cents', 1332,
    'version', 'credits_v1_60_40'
  )
)
ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE public.app_settings IS
  'Application-level configuration registry. credit_purchase_economics now stores provisional buyer-credit economics constants.';

-- ---------------------------------------------------------------------------
-- 2) Business idempotency marker for credit purchases
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.credit_purchase_claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  license_id uuid NOT NULL REFERENCES public.licenses(id) ON DELETE RESTRICT,
  purchase_id uuid REFERENCES public.purchases(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_credit_purchase_claims_user_product UNIQUE (user_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_credit_purchase_claims_purchase_id
  ON public.credit_purchase_claims (purchase_id)
  WHERE purchase_id IS NOT NULL;

ALTER TABLE public.credit_purchase_claims ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own credit purchase claims" ON public.credit_purchase_claims;
CREATE POLICY "Users can view own credit purchase claims"
  ON public.credit_purchase_claims
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.set_credit_purchase_claims_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_purchase_claims_updated_at ON public.credit_purchase_claims;
CREATE TRIGGER trg_credit_purchase_claims_updated_at
  BEFORE UPDATE ON public.credit_purchase_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.set_credit_purchase_claims_updated_at();

COMMENT ON TABLE public.credit_purchase_claims IS
  'Business idempotency marker for credit purchases. V1 enforces one purchased product per user for credit mode.';

-- ---------------------------------------------------------------------------
-- 3) Replace RPC with hardened version
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purchase_beat_with_credits(
  p_product_id uuid,
  p_license_id uuid DEFAULT NULL
)
RETURNS TABLE (
  purchase_id uuid,
  product_id uuid,
  license_id uuid,
  credits_spent integer,
  balance_before integer,
  balance_after integer,
  entitlement_id uuid,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_license public.licenses%ROWTYPE;
  v_existing_purchase_id uuid;
  v_existing_claim public.credit_purchase_claims%ROWTYPE;
  v_existing_license_sales integer := 0;
  v_balance_before integer := 0;
  v_balance_after integer := 0;
  v_purchase_id uuid;
  v_entitlement_id uuid;
  v_non_exclusive_license_count integer := 0;
  v_credit_cost integer := 2;
  v_credit_unit_value_cents integer := 666;
  v_gross_reference_amount_cents integer := 1332;
  v_producer_share_bps integer := 6000;
  v_platform_share_bps integer := 4000;
  v_producer_share_cents integer := 799;
  v_platform_share_cents integer := 533;
  v_economics_version text := 'credits_v1_60_40';
  v_ledger_idempotency_key text;
  v_claim_id uuid;
  v_config jsonb := '{}'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = '22023';
  END IF;

  -- PostgreSQL guarantees that any unhandled exception aborts the entire function call transaction.
  -- Therefore no purchase, ledger row, entitlement or claim can persist partially if a later step fails.
  -- We still order writes as purchase -> ledger -> entitlement to keep access grants last.

  -- Serialize all credit mutations for the same user to prevent double spend.
  PERFORM pg_advisory_xact_lock(hashtext(v_uid::text));

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'product_deleted' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.product_type <> 'beat'::public.product_type THEN
    RAISE EXCEPTION 'product_not_credit_eligible' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'product_not_active' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.is_published IS NOT TRUE THEN
    RAISE EXCEPTION 'product_not_published' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.is_exclusive IS TRUE OR v_product.product_type = 'exclusive'::public.product_type THEN
    RAISE EXCEPTION 'exclusive_not_allowed_with_credits' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.is_sold IS TRUE OR v_product.sold_at IS NOT NULL OR v_product.sold_to_user_id IS NOT NULL THEN
    RAISE EXCEPTION 'product_not_available' USING ERRCODE = 'P0001';
  END IF;

  IF p_license_id IS NOT NULL THEN
    SELECT *
    INTO v_license
    FROM public.licenses
    WHERE id = p_license_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'license_not_found' USING ERRCODE = 'P0001';
    END IF;

    IF v_license.exclusive_allowed IS TRUE THEN
      RAISE EXCEPTION 'license_not_credit_eligible' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT COUNT(*)::integer
    INTO v_non_exclusive_license_count
    FROM public.licenses
    WHERE exclusive_allowed = false;

    IF v_non_exclusive_license_count = 0 THEN
      RAISE EXCEPTION 'no_non_exclusive_license_available' USING ERRCODE = 'P0001';
    END IF;

    IF v_non_exclusive_license_count > 1 THEN
      RAISE EXCEPTION 'license_selection_required' USING ERRCODE = 'P0001';
    END IF;

    SELECT *
    INTO v_license
    FROM public.licenses
    WHERE exclusive_allowed = false
    ORDER BY created_at ASC, id ASC
    LIMIT 1;
  END IF;

  SELECT p.id
  INTO v_existing_purchase_id
  FROM public.purchases p
  WHERE p.user_id = v_uid
    AND p.product_id = p_product_id
    AND p.status = 'completed'
  ORDER BY p.created_at DESC
  LIMIT 1;

  IF v_existing_purchase_id IS NOT NULL THEN
    RAISE EXCEPTION 'purchase_already_exists' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.credit_purchase_claims (
    user_id,
    product_id,
    license_id
  ) VALUES (
    v_uid,
    p_product_id,
    v_license.id
  )
  ON CONFLICT (user_id, product_id) DO NOTHING
  RETURNING id INTO v_claim_id;

  IF v_claim_id IS NULL THEN
    SELECT *
    INTO v_existing_claim
    FROM public.credit_purchase_claims
    WHERE user_id = v_uid
      AND product_id = p_product_id
    LIMIT 1;

    IF v_existing_claim.purchase_id IS NOT NULL THEN
      RAISE EXCEPTION 'duplicate_request' USING ERRCODE = 'P0001';
    END IF;

    RAISE EXCEPTION 'concurrent_purchase_conflict' USING ERRCODE = '40001';
  END IF;

  IF v_license.max_sales IS NOT NULL THEN
    SELECT COUNT(*)::integer
    INTO v_existing_license_sales
    FROM public.purchases p
    WHERE p.product_id = p_product_id
      AND p.license_id = v_license.id
      AND p.status = 'completed';

    IF v_existing_license_sales >= v_license.max_sales THEN
      RAISE EXCEPTION 'license_sales_limit_reached' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  SELECT value
  INTO v_config
  FROM public.app_settings
  WHERE key = 'credit_purchase_economics';

  v_credit_cost := GREATEST(COALESCE((v_config->>'credit_cost_per_beat')::integer, v_credit_cost), 1);
  v_credit_unit_value_cents := GREATEST(COALESCE((v_config->>'credit_unit_value_cents')::integer, v_credit_unit_value_cents), 0);
  v_producer_share_bps := GREATEST(LEAST(COALESCE((v_config->>'producer_share_bps')::integer, v_producer_share_bps), 10000), 0);
  v_platform_share_bps := GREATEST(LEAST(COALESCE((v_config->>'platform_share_bps')::integer, v_platform_share_bps), 10000), 0);
  v_economics_version := COALESCE(NULLIF(v_config->>'version', ''), v_economics_version);

  IF v_producer_share_bps + v_platform_share_bps <> 10000 THEN
    RAISE EXCEPTION 'invalid_credit_purchase_economics_config' USING ERRCODE = 'P0001';
  END IF;

  v_gross_reference_amount_cents := COALESCE(
    NULLIF((v_config->>'gross_reference_amount_cents')::integer, 0),
    v_credit_cost * v_credit_unit_value_cents
  );

  IF v_gross_reference_amount_cents < 0 THEN
    RAISE EXCEPTION 'invalid_credit_purchase_economics_config' USING ERRCODE = 'P0001';
  END IF;

  v_producer_share_cents := FLOOR((v_gross_reference_amount_cents::numeric * v_producer_share_bps::numeric) / 10000)::integer;
  v_platform_share_cents := v_gross_reference_amount_cents - v_producer_share_cents;

  SELECT COALESCE(SUM(l.balance_delta), 0)::integer
  INTO v_balance_before
  FROM public.user_credit_ledger l
  WHERE l.user_id = v_uid;

  IF v_balance_before < v_credit_cost THEN
    RAISE EXCEPTION 'insufficient_credits' USING ERRCODE = 'P0001';
  END IF;

  v_balance_after := v_balance_before - v_credit_cost;

  INSERT INTO public.purchases (
    user_id,
    product_id,
    producer_id,
    amount,
    currency,
    status,
    is_exclusive,
    license_type,
    license_id,
    completed_at,
    download_expires_at,
    purchase_source,
    credits_spent,
    credit_unit_value_cents_snapshot,
    gross_reference_amount_cents,
    producer_share_cents_snapshot,
    platform_share_cents_snapshot,
    price_snapshot,
    currency_snapshot,
    license_type_snapshot,
    license_name_snapshot,
    metadata
  ) VALUES (
    v_uid,
    p_product_id,
    v_product.producer_id,
    0,
    'eur',
    'completed',
    false,
    v_license.name,
    v_license.id,
    now(),
    now() + interval '7 days',
    'credits',
    v_credit_cost,
    v_credit_unit_value_cents,
    v_gross_reference_amount_cents,
    v_producer_share_cents,
    v_platform_share_cents,
    v_gross_reference_amount_cents,
    'eur',
    v_license.name,
    v_license.name,
    jsonb_build_object(
      'purchase_mode', 'credits',
      'credit_cost', v_credit_cost,
      'credit_unit_value_cents_snapshot', v_credit_unit_value_cents,
      'gross_reference_amount_cents', v_gross_reference_amount_cents,
      'producer_share_cents_snapshot', v_producer_share_cents,
      'platform_share_cents_snapshot', v_platform_share_cents,
      'economic_snapshot_version', v_economics_version
    )
  )
  RETURNING id INTO v_purchase_id;

  IF v_purchase_id IS NULL THEN
    RAISE EXCEPTION 'concurrent_purchase_conflict' USING ERRCODE = '40001';
  END IF;

  UPDATE public.credit_purchase_claims
  SET purchase_id = v_purchase_id
  WHERE id = v_claim_id;

  v_ledger_idempotency_key := format('credit_purchase:%s', v_purchase_id::text);

  INSERT INTO public.user_credit_ledger (
    user_id,
    purchase_id,
    entry_type,
    direction,
    credits_amount,
    balance_delta,
    running_balance,
    reason,
    idempotency_key,
    metadata
  ) VALUES (
    v_uid,
    v_purchase_id,
    'purchase_debit',
    'debit',
    v_credit_cost,
    -v_credit_cost,
    v_balance_after,
    'credit_purchase',
    v_ledger_idempotency_key,
    jsonb_build_object(
      'product_id', p_product_id,
      'license_id', v_license.id,
      'purchase_source', 'credits'
    )
  );

  INSERT INTO public.entitlements (
    user_id,
    product_id,
    purchase_id,
    entitlement_type
  ) VALUES (
    v_uid,
    p_product_id,
    v_purchase_id,
    'purchase'
  )
  ON CONFLICT (user_id, product_id) DO UPDATE
  SET
    purchase_id = EXCLUDED.purchase_id,
    is_active = true,
    granted_at = now()
  RETURNING id INTO v_entitlement_id;

  UPDATE public.user_profiles
  SET total_purchases = total_purchases + 1
  WHERE id = v_uid;

  RETURN QUERY
  SELECT
    v_purchase_id,
    p_product_id,
    v_license.id,
    v_credit_cost,
    v_balance_before,
    v_balance_after,
    v_entitlement_id,
    'completed'::text;
END;
$$;

COMMENT ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) IS
  'Atomic non-exclusive beat purchase with credits. Uses business idempotency via credit_purchase_claims and economics constants from app_settings.credit_purchase_economics.';

COMMIT;
