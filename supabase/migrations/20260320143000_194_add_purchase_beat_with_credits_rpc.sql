/*
  # Credit purchase RPC for non-exclusive beats

  V1 business rules:
  - 1 non-exclusive beat = 2 credits
  - exclusive purchases are not allowed with credits
  - economic snapshots are provisional and isolated in this function:
    - credit unit value = 666 cents
    - gross reference amount = 1332 cents
    - producer share = 60%
    - platform share = 40%
*/

BEGIN;

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
  v_existing_license_sales integer := 0;
  v_balance_before integer := 0;
  v_balance_after integer := 0;
  v_purchase_id uuid;
  v_entitlement_id uuid;
  v_credit_cost constant integer := 2;
  v_credit_unit_value_cents constant integer := 666;
  v_gross_reference_amount_cents constant integer := 1332;
  v_producer_share_cents constant integer := 799;
  v_platform_share_cents constant integer := 533;
  v_ledger_idempotency_key text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = '22023';
  END IF;

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

  IF v_product.is_sold IS TRUE THEN
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
  ELSE
    SELECT *
    INTO v_license
    FROM public.licenses
    WHERE exclusive_allowed = false
    ORDER BY
      CASE WHEN lower(name) = 'standard' THEN 0 ELSE 1 END,
      price ASC,
      created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'no_non_exclusive_license_available' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_license.exclusive_allowed IS TRUE THEN
    RAISE EXCEPTION 'license_not_credit_eligible' USING ERRCODE = 'P0001';
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
      'economic_snapshot_version', 'credits_v1_60_40'
    )
  )
  RETURNING id INTO v_purchase_id;

  IF v_purchase_id IS NULL THEN
    RAISE EXCEPTION 'concurrent_purchase_conflict' USING ERRCODE = '40001';
  END IF;

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

REVOKE EXECUTE ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.purchase_beat_with_credits(uuid, uuid) IS
  'Atomic non-exclusive beat purchase with credits. V1 constants: 2 credits, 666 cents per credit, gross reference 1332 cents, producer/platform split 60/40.';

COMMIT;
