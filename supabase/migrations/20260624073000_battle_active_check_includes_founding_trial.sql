/*
  # Battle active-producer check must include founding trial

  Bug:
  - Battle creation gate (public.assert_battle_create_validations) and the
    official-battle application path (private.apply_to_admin_battle_campaign)
    gated on the RAW column user_profiles.is_producer_active = true.
  - That column is only set by the Stripe subscription trigger. It does NOT
    reflect an active founding trial. A founding producer with a valid trial
    (is_founding_producer = true, founding_trial_start set, campaign active and
    not expired) therefore has is_producer_active = false, yet is a fully
    active producer everywhere else (catalog, leaderboard, suggest_opponents).
  - Result: founding-trial producers were wrongly rejected with
    BATTLE_PRODUCER1/2_NOT_ACTIVE (classic battles) or producer_active_required
    (official battles), even though suggest_opponents lists them as valid
    opponents.

  Fix:
  - Use the canonical public.is_active_producer(uuid) =
    (is_producer_active = true) OR private.is_in_active_trial(uuid)
    in place of the raw column. Producers with neither an active Stripe
    subscription nor a valid trial stay blocked, as intended.

  Note:
  - private.is_active_battle_opponent() has the same raw-column check but is
    dead code: its only caller was the battles INSERT RLS policy that the
    battle create validation gate (20260530150000) closed. Left untouched.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.assert_battle_create_validations(
  p_producer1_id uuid,
  p_producer2_id uuid,
  p_product1_id uuid DEFAULT NULL,
  p_product2_id uuid DEFAULT NULL,
  p_require_products boolean DEFAULT false,
  p_max_elo_diff integer DEFAULT 400
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_producer1_active boolean := false;
  v_producer2_active boolean := false;
  v_producer1_elo integer := 1200;
  v_producer2_elo integer := 1200;
  v_max_elo_diff integer := 400;
BEGIN
  IF p_producer1_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCER1_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF p_producer2_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCER2_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF p_producer1_id = p_producer2_id THEN
    RAISE EXCEPTION 'BATTLE_CANNOT_BATTLE_SELF' USING ERRCODE = 'P0001';
  END IF;

  IF p_product1_id IS NOT NULL
     AND p_product2_id IS NOT NULL
     AND p_product1_id = p_product2_id THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT_DUPLICATE_IN_BATTLE'
      USING ERRCODE = '23505',
            DETAIL = jsonb_build_object(
              'product_id', p_product1_id,
              'producer1_id', p_producer1_id,
              'producer2_id', p_producer2_id
            )::text;
  END IF;

  -- Active = active Stripe subscription OR valid founding trial (is_active_producer)
  SELECT
    (
      up.role IN ('producer'::public.user_role, 'admin'::public.user_role)
      AND public.is_active_producer(up.id) = true
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
    ),
    COALESCE(up.elo_rating, 1200)
  INTO v_producer1_active, v_producer1_elo
  FROM public.user_profiles up
  WHERE up.id = p_producer1_id
  LIMIT 1;

  IF NOT FOUND OR COALESCE(v_producer1_active, false) = false THEN
    RAISE EXCEPTION 'BATTLE_PRODUCER1_NOT_ACTIVE'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('producer1_id', p_producer1_id)::text;
  END IF;

  SELECT
    (
      up.role IN ('producer'::public.user_role, 'admin'::public.user_role)
      AND public.is_active_producer(up.id) = true
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
    ),
    COALESCE(up.elo_rating, 1200)
  INTO v_producer2_active, v_producer2_elo
  FROM public.user_profiles up
  WHERE up.id = p_producer2_id
  LIMIT 1;

  IF NOT FOUND OR COALESCE(v_producer2_active, false) = false THEN
    RAISE EXCEPTION 'BATTLE_PRODUCER2_NOT_ACTIVE'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('producer2_id', p_producer2_id)::text;
  END IF;

  v_max_elo_diff := CASE
    WHEN p_max_elo_diff IS NULL OR p_max_elo_diff < 0 THEN 400
    ELSE p_max_elo_diff
  END;

  IF abs(v_producer1_elo - v_producer2_elo) > v_max_elo_diff THEN
    RAISE EXCEPTION 'BATTLE_SKILL_GAP_TOO_HIGH'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object(
              'producer1_id', p_producer1_id,
              'producer2_id', p_producer2_id,
              'producer1_elo', v_producer1_elo,
              'producer2_elo', v_producer2_elo,
              'max_elo_diff', v_max_elo_diff,
              'elo_diff', abs(v_producer1_elo - v_producer2_elo)
            )::text;
  END IF;

  IF p_require_products AND p_product1_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF p_require_products AND p_product2_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT2_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  IF p_product1_id IS NOT NULL
     AND NOT public.is_battle_product_eligible(p_product1_id, p_producer1_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_INVALID'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object(
              'product1_id', p_product1_id,
              'producer1_id', p_producer1_id,
              'required_product_type', 'beat',
              'required_status', 'active',
              'required_is_published', true
            )::text;
  END IF;

  IF p_product2_id IS NOT NULL
     AND NOT public.is_battle_product_eligible(p_product2_id, p_producer2_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT2_INVALID'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object(
              'product2_id', p_product2_id,
              'producer2_id', p_producer2_id,
              'required_product_type', 'beat',
              'required_status', 'active',
              'required_is_published', true
            )::text;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.apply_to_admin_battle_campaign(
  p_campaign_id uuid,
  p_message text DEFAULT NULL::text,
  p_proposed_product_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(success boolean, status text, message text, application_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_campaign public.admin_battle_campaigns%ROWTYPE;
  v_application_id uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'auth_required';
  END IF;

  IF NOT public.is_current_user_active(v_actor) THEN
    RAISE EXCEPTION 'account_deleted_or_inactive';
  END IF;

  -- Active = active Stripe subscription OR valid founding trial (is_active_producer)
  PERFORM 1
  FROM public.user_profiles up
  WHERE up.id = v_actor
    AND up.role IN ('producer', 'admin')
    AND public.is_active_producer(up.id) = true
    AND COALESCE(up.is_deleted, false) = false
    AND up.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'producer_active_required';
  END IF;

  SELECT *
  INTO v_campaign
  FROM public.admin_battle_campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_not_found';
  END IF;

  IF v_campaign.status <> 'applications_open' THEN
    RAISE EXCEPTION 'campaign_not_open';
  END IF;

  IF v_campaign.participation_deadline < now() THEN
    RAISE EXCEPTION 'campaign_participation_closed';
  END IF;

  IF p_proposed_product_id IS NOT NULL THEN
    PERFORM 1
    FROM public.products p
    WHERE p.id = p_proposed_product_id
      AND p.producer_id = v_actor
      AND p.product_type = 'beat'
      AND p.status = 'active'
      AND p.is_published = true
      AND p.deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_proposed_product';
    END IF;
  END IF;

  INSERT INTO public.admin_battle_applications (
    campaign_id,
    producer_id,
    message,
    proposed_product_id,
    admin_feedback,
    admin_feedback_at,
    status
  )
  VALUES (
    p_campaign_id,
    v_actor,
    NULLIF(btrim(COALESCE(p_message, '')), ''),
    p_proposed_product_id,
    NULL,
    NULL,
    'pending'
  )
  ON CONFLICT (campaign_id, producer_id)
  DO UPDATE SET
    message = EXCLUDED.message,
    proposed_product_id = EXCLUDED.proposed_product_id,
    admin_feedback = NULL,
    admin_feedback_at = NULL,
    status = 'pending'::public.admin_battle_application_status,
    updated_at = now()
  RETURNING id INTO v_application_id;

  RETURN QUERY
  SELECT true, 'applied'::text, 'Application submitted.'::text, v_application_id;
END;
$$;

COMMIT;
