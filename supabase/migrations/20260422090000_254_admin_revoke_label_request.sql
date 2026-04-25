/*
  # Admin revoke label access RPC

  Problem:
  - Admin can approve label requests but cannot revoke label access.
  - The UI has no safe server-side path to remove `account_type = 'label'`.

  Goal:
  - Allow admin to remove label access from a selected company.
  - Restore the account to `producer` when the account is a producer, otherwise `user`.
  - Mark the handled request as `rejected` so it no longer appears as approved.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_revoke_label_request(
  p_request_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_request public.label_requests%ROWTYPE;
  v_target public.user_profiles%ROWTYPE;
  v_account_type text;
BEGIN
  IF v_actor IS NULL OR NOT COALESCE(public.is_admin(v_actor), false) THEN
    RAISE EXCEPTION 'admin_required'
      USING ERRCODE = '42501';
  END IF;

  IF p_request_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'label_request_arguments_required'
      USING ERRCODE = '23502';
  END IF;

  SELECT *
  INTO v_request
  FROM public.label_requests lr
  WHERE lr.id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'label_request_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_request.user_id <> p_user_id THEN
    RAISE EXCEPTION 'label_request_user_mismatch'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO v_target
  FROM public.user_profiles up
  WHERE up.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  v_account_type := CASE
    WHEN v_target.role = 'producer'::public.user_role
      OR COALESCE(v_target.is_producer_active, false) = true
    THEN 'producer'
    ELSE 'user'
  END;

  UPDATE public.user_profiles
  SET account_type = v_account_type,
      is_verified = false
  WHERE id = p_user_id;

  UPDATE public.label_requests
  SET status = 'rejected',
      reviewed_at = now(),
      reviewed_by = v_actor
  WHERE id = p_request_id;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_revoke_label_request(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_revoke_label_request(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_revoke_label_request(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_revoke_label_request(uuid, uuid) TO service_role;

COMMIT;
