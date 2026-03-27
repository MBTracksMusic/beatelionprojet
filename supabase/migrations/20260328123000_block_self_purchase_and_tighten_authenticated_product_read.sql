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
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_existing_purchase_id uuid;
  v_existing_claim public.credit_purchase_claims%ROWTYPE;
  v_balance_before integer := 0;
  v_balance_after integer := 0;
  v_purchase_id uuid;
  v_entitlement_id uuid;
  v_required_credits integer := 0;
  v_credit_unit_value_cents integer := 1000;
  v_gross_reference_amount_cents integer := 0;
  v_producer_share_bps integer := 6000;
  v_platform_share_bps integer := 4000;
  v_producer_share_cents integer := 0;
  v_platform_share_cents integer := 0;
  v_economics_version text := 'credits_v4_fixed_unit_value';
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

  PERFORM pg_advisory_xact_lock(hashtext(v_uid::text));

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.producer_id = v_uid THEN
    RAISE EXCEPTION 'self_purchase_forbidden' USING ERRCODE = '42501';
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

  IF v_product.early_access_until IS NOT NULL
    AND v_product.early_access_until > now()
    AND public.user_has_active_buyer_subscription(v_uid) IS NOT TRUE THEN
    RAISE EXCEPTION 'early_access_premium_only' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.is_exclusive IS TRUE OR v_product.product_type = 'exclusive'::public.product_type THEN
    RAISE EXCEPTION 'exclusive_not_allowed_with_credits' USING ERRCODE = 'P0001';
  END IF;

  IF v_product.is_sold IS TRUE OR v_product.sold_at IS NOT NULL OR v_product.sold_to_user_id IS NOT NULL THEN
    RAISE EXCEPTION 'product_not_available' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE(v_product.price, 0) <= 0 THEN
    RAISE EXCEPTION 'product_not_credit_eligible' USING ERRCODE = 'P0001';
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
    NULL
  )
  ON CONFLICT (user_id, product_id) DO NOTHING
  RETURNING id INTO v_claim_id;

  IF v_claim_id IS NULL THEN
    SELECT *
    INTO v_existing_claim
    FROM public.credit_purchase_claims cpc
    WHERE cpc.user_id = v_uid
      AND cpc.product_id = p_product_id
    LIMIT 1;

    IF v_existing_claim.purchase_id IS NOT NULL THEN
      RAISE EXCEPTION 'duplicate_request' USING ERRCODE = 'P0001';
    END IF;

    RAISE EXCEPTION 'concurrent_purchase_conflict' USING ERRCODE = '40001';
  END IF;

  SELECT value
  INTO v_config
  FROM public.app_settings
  WHERE key = 'credit_purchase_economics';

  v_producer_share_bps := GREATEST(LEAST(COALESCE((v_config->>'producer_share_bps')::integer, v_producer_share_bps), 10000), 0);
  v_platform_share_bps := GREATEST(LEAST(COALESCE((v_config->>'platform_share_bps')::integer, v_platform_share_bps), 10000), 0);
  v_economics_version := COALESCE(NULLIF(v_config->>'version', ''), v_economics_version);

  IF v_producer_share_bps + v_platform_share_bps <> 10000 THEN
    RAISE EXCEPTION 'invalid_credit_purchase_economics_config' USING ERRCODE = 'P0001';
  END IF;

  v_gross_reference_amount_cents := v_product.price;
  v_required_credits := GREATEST(
    CEIL(v_gross_reference_amount_cents::numeric / 1000::numeric)::integer,
    1
  );

  v_producer_share_cents := FLOOR((v_gross_reference_amount_cents::numeric * v_producer_share_bps::numeric) / 10000)::integer;
  v_platform_share_cents := v_gross_reference_amount_cents - v_producer_share_cents;

  SELECT COALESCE(SUM(l.balance_delta), 0)::integer
  INTO v_balance_before
  FROM public.user_credit_ledger l
  WHERE l.user_id = v_uid;

  IF v_balance_before < v_required_credits THEN
    RAISE EXCEPTION 'insufficient_credits' USING ERRCODE = 'P0001';
  END IF;

  v_balance_after := v_balance_before - v_required_credits;

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
    'standard',
    NULL,
    now(),
    now() + interval '7 days',
    'credits',
    v_required_credits,
    v_credit_unit_value_cents,
    v_gross_reference_amount_cents,
    v_producer_share_cents,
    v_platform_share_cents,
    v_gross_reference_amount_cents,
    'eur',
    'standard',
    'Standard',
    jsonb_build_object(
      'purchase_mode', 'credits',
      'credit_cost', v_required_credits,
      'credit_unit_value_cents_snapshot', v_credit_unit_value_cents,
      'gross_reference_amount_cents', v_gross_reference_amount_cents,
      'producer_share_cents_snapshot', v_producer_share_cents,
      'platform_share_cents_snapshot', v_platform_share_cents,
      'economic_snapshot_version', v_economics_version,
      'price_source', 'products.price',
      'payout_mode', 'platform_fallback',
      'payout_amount', v_producer_share_cents,
      'requires_manual_payout', true,
      'payout_status', 'pending',
      'tracked_at', now(),
      'payout_source', 'credit_purchase'
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
    v_required_credits,
    -v_required_credits,
    v_balance_after,
    'credit_purchase',
    v_ledger_idempotency_key,
    jsonb_build_object(
      'product_id', p_product_id,
      'purchase_source', 'credits',
      'price_source', 'products.price'
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
    NULL::uuid,
    v_required_credits,
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

CREATE OR REPLACE FUNCTION public.complete_license_purchase(
  p_product_id uuid,
  p_user_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_license_id uuid,
  p_amount integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase_id uuid;
  v_existing_purchase_id uuid;
  v_producer_id uuid;
  v_product public.products%ROWTYPE;
  v_license public.licenses%ROWTYPE;
  v_existing_license_sales integer;
  v_lock public.exclusive_locks%ROWTYPE;
  v_is_new_purchase boolean := false;
BEGIN
  IF p_checkout_session_id IS NULL OR btrim(p_checkout_session_id) = '' THEN
    RAISE EXCEPTION 'Missing checkout session id';
  END IF;

  IF p_payment_intent_id IS NULL OR btrim(p_payment_intent_id) = '' THEN
    RAISE EXCEPTION 'Missing payment intent id';
  END IF;

  SELECT id
  INTO v_existing_purchase_id
  FROM public.purchases
  WHERE stripe_payment_intent_id = p_payment_intent_id
     OR stripe_checkout_session_id = p_checkout_session_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_existing_purchase_id IS NOT NULL THEN
    RETURN v_existing_purchase_id;
  END IF;

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id;
  END IF;

  IF v_product.producer_id = p_user_id THEN
    RAISE EXCEPTION 'self_purchase_forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_license
  FROM public.licenses
  WHERE id = p_license_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'License not found: %', p_license_id;
  END IF;

  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'Invalid amount snapshot: %', p_amount;
  END IF;

  IF v_product.is_exclusive AND NOT v_license.exclusive_allowed THEN
    RAISE EXCEPTION 'License % does not allow exclusive purchase', v_license.name;
  END IF;

  IF v_product.is_exclusive THEN
    IF v_product.is_sold THEN
      RAISE EXCEPTION 'This exclusive product has already been sold';
    END IF;

    SELECT *
    INTO v_lock
    FROM public.exclusive_locks
    WHERE product_id = p_product_id
      AND stripe_checkout_session_id = p_checkout_session_id;

    IF NOT FOUND THEN
      RAISE NOTICE 'complete_license_purchase: missing lock for paid exclusive checkout %, product %, user %; proceeding',
        p_checkout_session_id, p_product_id, p_user_id;
    END IF;
  END IF;

  IF v_license.max_sales IS NOT NULL THEN
    SELECT count(*)
    INTO v_existing_license_sales
    FROM public.purchases
    WHERE product_id = p_product_id
      AND license_id = p_license_id
      AND status = 'completed';

    IF v_existing_license_sales >= v_license.max_sales THEN
      RAISE EXCEPTION 'License % reached max sales limit for this product', v_license.name;
    END IF;
  END IF;

  v_producer_id := v_product.producer_id;

  INSERT INTO public.purchases (
    user_id,
    product_id,
    producer_id,
    stripe_payment_intent_id,
    stripe_checkout_session_id,
    amount,
    status,
    is_exclusive,
    license_type,
    license_id,
    completed_at,
    download_expires_at,
    metadata
  ) VALUES (
    p_user_id,
    p_product_id,
    v_producer_id,
    p_payment_intent_id,
    p_checkout_session_id,
    p_amount,
    'completed',
    v_product.is_exclusive,
    v_license.name,
    v_license.id,
    now(),
    CASE
      WHEN v_product.is_exclusive THEN now() + interval '24 hours'
      ELSE now() + interval '7 days'
    END,
    jsonb_build_object(
      'license_id', v_license.id,
      'license_name', v_license.name,
      'max_streams', v_license.max_streams,
      'max_sales', v_license.max_sales,
      'youtube_monetization', v_license.youtube_monetization,
      'music_video_allowed', v_license.music_video_allowed,
      'credit_required', v_license.credit_required,
      'exclusive_allowed', v_license.exclusive_allowed,
      'price_source', 'checkout.metadata.db_price_snapshot'
    )
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_purchase_id;

  IF v_purchase_id IS NULL THEN
    SELECT id
    INTO v_purchase_id
    FROM public.purchases
    WHERE stripe_payment_intent_id = p_payment_intent_id
       OR stripe_checkout_session_id = p_checkout_session_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_purchase_id IS NULL THEN
      SELECT id
      INTO v_purchase_id
      FROM public.purchases
      WHERE user_id = p_user_id
        AND product_id = p_product_id
        AND status = 'completed'
      ORDER BY created_at DESC
      LIMIT 1;
    END IF;

    IF v_purchase_id IS NULL THEN
      RAISE EXCEPTION 'Could not resolve existing purchase for payment intent %', p_payment_intent_id;
    END IF;
  ELSE
    v_is_new_purchase := true;
  END IF;

  INSERT INTO public.entitlements (
    user_id,
    product_id,
    purchase_id,
    entitlement_type
  ) VALUES (
    p_user_id,
    p_product_id,
    v_purchase_id,
    'purchase'
  )
  ON CONFLICT (user_id, product_id) DO UPDATE SET
    purchase_id = EXCLUDED.purchase_id,
    is_active = true,
    granted_at = now();

  IF v_product.is_exclusive THEN
    UPDATE public.products
    SET
      is_sold = true,
      sold_at = now(),
      sold_to_user_id = p_user_id,
      is_published = false
    WHERE id = p_product_id;

    DELETE FROM public.exclusive_locks
    WHERE product_id = p_product_id;
  END IF;

  IF v_is_new_purchase THEN
    UPDATE public.user_profiles
    SET total_purchases = total_purchases + 1
    WHERE id = p_user_id;
  END IF;

  RETURN v_purchase_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.complete_license_purchase(uuid, uuid, text, text, uuid, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_license_purchase(uuid, uuid, text, text, uuid, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_license_purchase(uuid, uuid, text, text, uuid, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.complete_license_purchase(uuid, uuid, text, text, uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_exclusive_purchase(
  p_product_id uuid,
  p_user_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase_id uuid;
  v_producer_id uuid;
  v_lock exclusive_locks%ROWTYPE;
BEGIN
  SELECT * INTO v_lock FROM exclusive_locks
  WHERE product_id = p_product_id
  AND stripe_checkout_session_id = p_checkout_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No valid lock found for this purchase';
  END IF;

  SELECT producer_id INTO v_producer_id FROM products WHERE id = p_product_id;

  IF v_producer_id = p_user_id THEN
    RAISE EXCEPTION 'self_purchase_forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO purchases (
    user_id, product_id, producer_id,
    stripe_payment_intent_id, stripe_checkout_session_id,
    amount, status, is_exclusive, completed_at,
    download_expires_at
  ) VALUES (
    p_user_id, p_product_id, v_producer_id,
    p_payment_intent_id, p_checkout_session_id,
    p_amount, 'completed', true, now(),
    now() + interval '24 hours'
  ) RETURNING id INTO v_purchase_id;

  INSERT INTO entitlements (user_id, product_id, purchase_id, entitlement_type)
  VALUES (p_user_id, p_product_id, v_purchase_id, 'purchase')
  ON CONFLICT (user_id, product_id) DO UPDATE SET
    purchase_id = EXCLUDED.purchase_id,
    is_active = true,
    granted_at = now();

  UPDATE products SET
    is_sold = true,
    sold_at = now(),
    sold_to_user_id = p_user_id,
    is_published = false
  WHERE id = p_product_id;

  DELETE FROM exclusive_locks WHERE product_id = p_product_id;

  UPDATE user_profiles SET
    total_purchases = total_purchases + 1
  WHERE id = p_user_id;

  RETURN v_purchase_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.complete_exclusive_purchase(uuid, uuid, text, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_exclusive_purchase(uuid, uuid, text, text, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_exclusive_purchase(uuid, uuid, text, text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.complete_exclusive_purchase(uuid, uuid, text, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_standard_purchase(
  p_product_id uuid,
  p_user_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount integer,
  p_license_type text DEFAULT 'standard'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase_id uuid;
  v_producer_id uuid;
BEGIN
  SELECT producer_id INTO v_producer_id FROM products WHERE id = p_product_id;

  IF v_producer_id = p_user_id THEN
    RAISE EXCEPTION 'self_purchase_forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO purchases (
    user_id, product_id, producer_id,
    stripe_payment_intent_id, stripe_checkout_session_id,
    amount, status, is_exclusive, license_type, completed_at,
    download_expires_at
  ) VALUES (
    p_user_id, p_product_id, v_producer_id,
    p_payment_intent_id, p_checkout_session_id,
    p_amount, 'completed', false, p_license_type, now(),
    now() + interval '7 days'
  ) RETURNING id INTO v_purchase_id;

  INSERT INTO entitlements (user_id, product_id, purchase_id, entitlement_type)
  VALUES (p_user_id, p_product_id, v_purchase_id, 'purchase')
  ON CONFLICT (user_id, product_id) DO UPDATE SET
    purchase_id = EXCLUDED.purchase_id,
    is_active = true,
    granted_at = now();

  UPDATE user_profiles SET
    total_purchases = total_purchases + 1
  WHERE id = p_user_id;

  RETURN v_purchase_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.complete_standard_purchase(uuid, uuid, text, text, integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_standard_purchase(uuid, uuid, text, text, integer, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_standard_purchase(uuid, uuid, text, text, integer, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.complete_standard_purchase(uuid, uuid, text, text, integer, text) TO service_role;

DROP POLICY IF EXISTS "Authenticated users can view products" ON public.products;

CREATE POLICY "Authenticated users can view products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    is_published = true
    OR producer_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.cart_items ci
      WHERE ci.user_id = auth.uid()
        AND ci.product_id = products.id
    )
    OR EXISTS (
      SELECT 1
      FROM public.wishlists w
      WHERE w.user_id = auth.uid()
        AND w.product_id = products.id
    )
    OR EXISTS (
      SELECT 1
      FROM public.purchases pur
      WHERE pur.user_id = auth.uid()
        AND pur.product_id = products.id
    )
  );

COMMIT;
