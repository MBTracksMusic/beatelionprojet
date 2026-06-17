BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.admin_unassign_producer_campaign(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_profile_role public.user_role;
  v_has_active_subscription boolean := false;
  v_active_subscription_tier public.producer_tier_type;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Unauthorized: admin role required'
      USING ERRCODE = '42501';
  END IF;

  SELECT role
  INTO v_profile_role
  FROM public.user_profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found: %', p_user_id
      USING ERRCODE = '02000';
  END IF;

  SELECT ps.producer_tier
  INTO v_active_subscription_tier
  FROM public.producer_subscriptions ps
  WHERE ps.user_id = p_user_id
    AND ps.is_producer_active = true
    AND ps.subscription_status IN ('active', 'trialing')
    AND ps.current_period_end > now()
  LIMIT 1;

  v_has_active_subscription := FOUND;

  UPDATE public.user_profiles
  SET
    producer_campaign_type = NULL,
    is_founding_producer = false,
    founding_trial_start = NULL,
    commission_rate_override = NULL,
    is_producer_active = v_has_active_subscription,
    role = CASE
      WHEN v_profile_role = 'admin'::public.user_role THEN 'admin'::public.user_role
      WHEN v_has_active_subscription THEN 'producer'::public.user_role
      ELSE 'user'::public.user_role
    END,
    producer_tier = CASE
      WHEN v_has_active_subscription
      THEN COALESCE(v_active_subscription_tier, 'producteur'::public.producer_tier_type)
      ELSE 'user'::public.producer_tier_type
    END,
    updated_at = now()
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'message', CASE
      WHEN v_has_active_subscription
      THEN 'Producer removed from campaign; paid producer access preserved'
      ELSE 'Producer removed from campaign; producer access revoked'
    END,
    'producer_access_revoked', NOT v_has_active_subscription,
    'has_active_subscription', v_has_active_subscription
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_unassign_producer_campaign(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.admin_unassign_producer_campaign(p_user_id);
$$;

REVOKE ALL ON FUNCTION private.admin_unassign_producer_campaign(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_unassign_producer_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_unassign_producer_campaign(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_unassign_producer_campaign(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.admin_reset_producer_campaign_trial(
  p_user_id uuid,
  p_campaign_type text,
  p_trial_start timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_campaign public.producer_campaigns%ROWTYPE;
  v_profile record;
  v_trial_end timestamptz;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Unauthorized: admin role required'
      USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO v_campaign
  FROM public.producer_campaigns
  WHERE type = p_campaign_type;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign not found: %', p_campaign_type
      USING ERRCODE = 'P0002';
  END IF;

  SELECT id, producer_campaign_type
  INTO v_profile
  FROM public.user_profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found: %', p_user_id
      USING ERRCODE = '02000';
  END IF;

  IF v_profile.producer_campaign_type IS DISTINCT FROM p_campaign_type THEN
    RAISE EXCEPTION 'User % is not assigned to campaign %', p_user_id, p_campaign_type
      USING ERRCODE = '22023';
  END IF;

  v_trial_end := p_trial_start + v_campaign.trial_duration;

  UPDATE public.user_profiles
  SET
    founding_trial_start = p_trial_start,
    is_founding_producer = CASE
      WHEN p_campaign_type = 'founding' THEN true
      ELSE is_founding_producer
    END,
    updated_at = now()
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'campaign_type', p_campaign_type,
    'trial_start', p_trial_start,
    'trial_end', v_trial_end,
    'days_remaining', GREATEST(0, EXTRACT(DAY FROM (v_trial_end - now()))::int)
  );
END;
$$;

COMMIT;
