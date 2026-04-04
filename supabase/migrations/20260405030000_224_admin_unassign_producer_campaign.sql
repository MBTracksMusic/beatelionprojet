/*
  # Admin unassign producer campaign

  ## Objectif
  Permettre à un admin de retirer proprement un producteur d'une campagne
  sans impacter Stripe ni supprimer le compte utilisateur.

  ## Règles
  - admin only via public.is_admin()
  - reset campaign fields only
  - do not touch producer_subscriptions / user_subscriptions / auth.users
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_unassign_producer_campaign(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Unauthorized: admin role required'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.user_profiles
  SET
    producer_campaign_type = NULL,
    is_founding_producer = false,
    founding_trial_start = NULL,
    updated_at = now()
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found: %', p_user_id
      USING ERRCODE = '02000';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'message', 'Producer removed from campaign'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_unassign_producer_campaign(uuid)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_unassign_producer_campaign(uuid)
  FROM anon;

COMMIT;
