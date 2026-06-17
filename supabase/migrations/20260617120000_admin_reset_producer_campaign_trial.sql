BEGIN;

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
    is_producer_active = true,
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

CREATE OR REPLACE FUNCTION public.admin_reset_producer_campaign_trial(
  p_user_id uuid,
  p_campaign_type text,
  p_trial_start timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.admin_reset_producer_campaign_trial(p_user_id, p_campaign_type, p_trial_start);
$$;

REVOKE ALL ON FUNCTION private.admin_reset_producer_campaign_trial(uuid, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_reset_producer_campaign_trial(uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_reset_producer_campaign_trial(uuid, text, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_reset_producer_campaign_trial(uuid, text, timestamptz) TO authenticated, service_role;

COMMIT;
