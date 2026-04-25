/*
  # Harden Label Announcements forum access helpers

  Tightens helper functions so public callers cannot use a UUID parameter to
  probe another user's label/subscription status. Service-role RPCs and admins
  can still evaluate access for the target user.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.forum_is_verified_label(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target uuid := COALESCE(p_user_id, auth.uid());
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_target IS NULL THEN
    RETURN false;
  END IF;

  IF v_jwt_role <> 'service_role'
     AND v_target IS DISTINCT FROM v_actor
     AND COALESCE(public.is_admin(v_actor), false) = false
     AND COALESCE(public.forum_is_assistant_user(v_actor), false) = false THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = v_target
      AND up.account_type = 'label'
      AND up.is_verified = true
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_has_active_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target uuid := COALESCE(p_user_id, auth.uid());
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF v_target IS NULL THEN
    RETURN false;
  END IF;

  IF v_jwt_role <> 'service_role'
     AND v_target IS DISTINCT FROM v_actor
     AND COALESCE(public.is_admin(v_actor), false) = false
     AND COALESCE(public.forum_is_assistant_user(v_actor), false) = false THEN
    RETURN false;
  END IF;

  IF COALESCE(public.is_admin(v_target), false)
     OR COALESCE(public.forum_is_assistant_user(v_target), false) THEN
    RETURN true;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.producer_subscriptions ps
    WHERE ps.user_id = v_target
      AND ps.subscription_status IN ('active', 'trialing')
      AND ps.current_period_end > now()
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_can_access_category(
  p_category_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target uuid := COALESCE(p_user_id, auth.uid());
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_category public.forum_categories%ROWTYPE;
  v_can_evaluate_target boolean;
BEGIN
  SELECT *
  INTO v_category
  FROM public.forum_categories
  WHERE id = p_category_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF COALESCE(v_category.is_premium_only, false) = false THEN
    RETURN public.forum_user_meets_rank_requirement(v_target, v_category.required_rank_tier);
  END IF;

  IF v_target IS NULL THEN
    RETURN false;
  END IF;

  v_can_evaluate_target :=
    v_jwt_role = 'service_role'
    OR v_target IS NOT DISTINCT FROM v_actor
    OR COALESCE(public.is_admin(v_actor), false)
    OR COALESCE(public.forum_is_assistant_user(v_actor), false);

  IF v_can_evaluate_target = false THEN
    RETURN false;
  END IF;

  IF NOT (
    public.forum_has_active_subscription(v_target)
    OR (
      v_category.slug = 'annonces-label'
      AND public.forum_is_verified_label(v_target)
    )
  ) THEN
    RETURN false;
  END IF;

  RETURN public.forum_user_meets_rank_requirement(v_target, v_category.required_rank_tier);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_can_write_topic(
  p_topic_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target uuid := COALESCE(p_user_id, auth.uid());
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_topic_deleted boolean;
  v_topic_locked boolean;
  v_category_slug text;
  v_category_premium boolean;
  v_required_rank_tier text;
  v_can_evaluate_target boolean;
BEGIN
  IF v_target IS NULL THEN
    RETURN false;
  END IF;

  v_can_evaluate_target :=
    v_jwt_role = 'service_role'
    OR v_target IS NOT DISTINCT FROM v_actor
    OR COALESCE(public.is_admin(v_actor), false)
    OR COALESCE(public.forum_is_assistant_user(v_actor), false);

  IF v_can_evaluate_target = false THEN
    RETURN false;
  END IF;

  SELECT
    COALESCE(ft.is_deleted, false),
    ft.is_locked,
    fc.slug,
    COALESCE(fc.is_premium_only, false),
    fc.required_rank_tier
  INTO
    v_topic_deleted,
    v_topic_locked,
    v_category_slug,
    v_category_premium,
    v_required_rank_tier
  FROM public.forum_topics ft
  JOIN public.forum_categories fc ON fc.id = ft.category_id
  WHERE ft.id = p_topic_id
  LIMIT 1;

  IF NOT FOUND OR v_topic_deleted OR v_topic_locked THEN
    RETURN false;
  END IF;

  IF v_category_premium
     AND NOT (
       public.forum_has_active_subscription(v_target)
       OR (
         v_category_slug = 'annonces-label'
         AND public.forum_is_verified_label(v_target)
       )
     ) THEN
    RETURN false;
  END IF;

  RETURN public.forum_user_meets_rank_requirement(v_target, v_required_rank_tier);
END;
$$;

REVOKE ALL ON FUNCTION public.forum_is_verified_label(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_is_verified_label(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.forum_is_verified_label(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_is_verified_label(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_is_verified_label(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_is_verified_label(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.forum_has_active_subscription(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_has_active_subscription(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.forum_has_active_subscription(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.forum_can_access_category(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_can_access_category(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.forum_can_access_category(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.forum_can_write_topic(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_can_write_topic(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.forum_can_write_topic(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO service_role;

COMMIT;
