/*
  # Harden cart + checkout product access

  Problem:
  - `cart_items` INSERT only checks `is_published` + sold/exclusive state.
  - Authenticated users can still read `products`, so a direct insert with a known
    product id can target an elite/private beat.
  - `create-checkout` and `purchase_beat_with_credits` do not currently re-check
    elite access server-side.

  Fix:
  - Add a server-side helper for elite catalog access.
  - Rebuild the cart INSERT policy to require product visibility for the actor.
  - Recreate `purchase_beat_with_credits` with the same elite access guard.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.user_has_elite_catalog_access(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = p_user_id
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
      AND (
        up.role = 'admin'
        OR up.account_type = 'elite_producer'
        OR (up.account_type = 'label' AND up.is_verified = true)
      )
  );
$$;

COMMENT ON FUNCTION public.user_has_elite_catalog_access(uuid) IS
  'Returns true when a user can access private elite catalog rows.';

REVOKE ALL ON FUNCTION public.user_has_elite_catalog_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.user_has_elite_catalog_access(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.user_has_elite_catalog_access(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_has_elite_catalog_access(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.user_can_add_product_to_cart(
  p_user_id uuid,
  p_product_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.products p
    WHERE p.id = p_product_id
      AND p.deleted_at IS NULL
      AND p.status = 'active'
      AND COALESCE(p.is_published, false) = true
      AND (
        COALESCE(p.is_exclusive, false) = false
        OR (
          COALESCE(p.is_sold, false) = false
          AND public.is_confirmed_user(p_user_id)
        )
      )
      AND (
        COALESCE(p.is_elite, false) = false
        OR public.user_has_elite_catalog_access(p_user_id)
      )
  );
$$;

COMMENT ON FUNCTION public.user_can_add_product_to_cart(uuid, uuid) IS
  'Server-side guard for cart eligibility, including elite catalog access.';

REVOKE ALL ON FUNCTION public.user_can_add_product_to_cart(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.user_can_add_product_to_cart(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.user_can_add_product_to_cart(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_can_add_product_to_cart(uuid, uuid) TO service_role;

DROP POLICY IF EXISTS "Users can add to cart" ON public.cart_items;
CREATE POLICY "Users can add to cart"
  ON public.cart_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND public.user_can_add_product_to_cart(auth.uid(), product_id)
  );

DROP FUNCTION IF EXISTS public.get_public_home_featured_beats(integer);

CREATE FUNCTION public.get_public_home_featured_beats(p_limit integer DEFAULT 10)
RETURNS TABLE (
  id uuid,
  title text,
  slug text,
  price integer,
  play_count integer,
  cover_image_url text,
  is_sold boolean,
  is_exclusive boolean,
  producer_id uuid,
  producer_username text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p.id,
    p.title,
    p.slug,
    p.price,
    COALESCE(p.play_count, 0) AS play_count,
    p.cover_image_url,
    COALESCE(p.is_sold, false) AS is_sold,
    COALESCE(p.is_exclusive, false) AS is_exclusive,
    p.producer_id,
    public.get_public_profile_label(up) AS producer_username
  FROM public.products p
  LEFT JOIN public.user_profiles up ON up.id = p.producer_id
  LEFT JOIN public.producer_beats_ranked pbr ON pbr.id = p.id
  WHERE p.product_type = 'beat'
    AND p.deleted_at IS NULL
    AND p.status = 'active'
    AND COALESCE(p.is_published, false) = true
    AND COALESCE(p.is_elite, false) = false
  ORDER BY
    CASE WHEN COALESCE(pbr.top_10_flag, false) THEN 0 ELSE 1 END ASC,
    COALESCE(pbr.performance_score, 0) DESC,
    COALESCE(p.play_count, 0) DESC,
    p.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 24);
$$;

COMMENT ON FUNCTION public.get_public_home_featured_beats(integer) IS
  'Returns public featured beats only, excluding private elite beats.';

REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM anon;
REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO service_role;

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

  IF COALESCE(v_product.is_elite, false) = true
     AND public.user_has_elite_catalog_access(v_uid) IS NOT TRUE THEN
    RAISE EXCEPTION 'elite_access_required' USING ERRCODE = '42501';
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

COMMIT;
