/*
  # Admin delete rejected label request RPC

  Problem:
  - Admin can revoke label access, but revoked rows remain in the admin list.
  - There is no safe server-side delete path for handled rejected requests.

  Goal:
  - Allow admins to delete only `rejected` label requests.
  - Keep `pending` and `approved` requests protected from accidental deletion.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_delete_rejected_label_request(
  p_request_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_request public.label_requests%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT COALESCE(public.is_admin(v_actor), false) THEN
    RAISE EXCEPTION 'admin_required'
      USING ERRCODE = '42501';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'label_request_id_required'
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

  IF v_request.status <> 'rejected' THEN
    RAISE EXCEPTION 'only_rejected_label_requests_can_be_deleted'
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.label_requests
  WHERE id = p_request_id;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_delete_rejected_label_request(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_rejected_label_request(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_rejected_label_request(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_rejected_label_request(uuid) TO service_role;

COMMIT;
