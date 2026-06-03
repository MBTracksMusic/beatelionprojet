/*
  # Move exposed SECURITY DEFINER implementations behind invoker wrappers

  Supabase Security Advisor flags SECURITY DEFINER functions in the exposed
  public schema when anon/authenticated can execute them through PostgREST RPC.

  Several of these functions are intentionally callable by the frontend or Edge
  Functions and contain their own auth.uid(), service_role, or is_admin checks.
  Revoking them from anon/authenticated would break existing product flows.

  This migration preserves the public RPC API while moving the privileged
  implementation into the non-exposed private schema. Public functions become
  SECURITY INVOKER wrappers with the same signatures and grants.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS extensions;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_net'
      AND n.nspname = 'public'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM pg_extension
      WHERE extname = 'pg_net'
        AND extrelocatable = true
    ) THEN
      ALTER EXTENSION pg_net SET SCHEMA extensions;
    ELSE
      RAISE NOTICE 'pg_net remains in public because this Supabase build marks it non-relocatable.';
    END IF;
  END IF;
END
$$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO service_role;

-- ---------------------------------------------------------------------------
-- Public anon RPCs.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.can_email_register(text) SET SCHEMA private;

CREATE FUNCTION public.can_email_register(p_email text)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.can_email_register(p_email);
$$;

REVOKE ALL ON FUNCTION private.can_email_register(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_email_register(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.can_email_register(text) TO anon, service_role;
GRANT EXECUTE ON FUNCTION public.can_email_register(text) TO anon, service_role;

COMMENT ON FUNCTION public.can_email_register(text) IS
  'Public SECURITY INVOKER wrapper for the private registration preflight implementation.';

ALTER FUNCTION public.get_public_producer_campaign_status(text) SET SCHEMA private;

CREATE FUNCTION public.get_public_producer_campaign_status(p_campaign_type text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.get_public_producer_campaign_status(p_campaign_type);
$$;

REVOKE ALL ON FUNCTION private.get_public_producer_campaign_status(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_producer_campaign_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_public_producer_campaign_status(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_producer_campaign_status(text) TO anon, authenticated, service_role;

ALTER FUNCTION public.get_weekly_leaderboard(integer) SET SCHEMA private;

CREATE FUNCTION public.get_weekly_leaderboard(p_limit integer DEFAULT 50)
RETURNS TABLE (
  user_id uuid,
  username text,
  weekly_wins integer,
  weekly_losses integer,
  weekly_winrate numeric,
  rank_position bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT *
  FROM private.get_weekly_leaderboard(p_limit);
$$;

REVOKE ALL ON FUNCTION private.get_weekly_leaderboard(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_weekly_leaderboard(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_weekly_leaderboard(integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboard(integer) TO anon, authenticated, service_role;

ALTER FUNCTION public.get_battle_feedback_payload(uuid, uuid) SET SCHEMA private;

CREATE FUNCTION public.get_battle_feedback_payload(
  p_battle_id uuid,
  p_viewer_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.get_battle_feedback_payload(p_battle_id, p_viewer_id);
$$;

REVOKE ALL ON FUNCTION private.get_battle_feedback_payload(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_battle_feedback_payload(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_battle_feedback_payload(uuid, uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_battle_feedback_payload(uuid, uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Forum RLS helper.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.forum_current_user_is_admin() SET SCHEMA private;

CREATE FUNCTION public.forum_current_user_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.forum_current_user_is_admin();
$$;

REVOKE ALL ON FUNCTION private.forum_current_user_is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_current_user_is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.forum_current_user_is_admin() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.forum_current_user_is_admin() TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Authenticated user/admin/battle RPCs.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.accept_waitlist_entry(uuid) SET SCHEMA private;

CREATE FUNCTION public.accept_waitlist_entry(p_waitlist_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.accept_waitlist_entry(p_waitlist_id);
$$;

REVOKE ALL ON FUNCTION private.accept_waitlist_entry(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_waitlist_entry(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.accept_waitlist_entry(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.accept_waitlist_entry(uuid) TO authenticated, service_role;

ALTER FUNCTION public.admin_assign_producer_campaign(uuid, text, timestamptz) SET SCHEMA private;

CREATE FUNCTION public.admin_assign_producer_campaign(
  p_user_id uuid,
  p_campaign_type text,
  p_trial_start timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.admin_assign_producer_campaign(p_user_id, p_campaign_type, p_trial_start);
$$;

REVOKE ALL ON FUNCTION private.admin_assign_producer_campaign(uuid, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_assign_producer_campaign(uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_assign_producer_campaign(uuid, text, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_assign_producer_campaign(uuid, text, timestamptz) TO authenticated, service_role;

ALTER FUNCTION public.admin_launch_battle_campaign(uuid) SET SCHEMA private;

CREATE FUNCTION public.admin_launch_battle_campaign(p_campaign_id uuid)
RETURNS TABLE (
  success boolean,
  status text,
  message text,
  battle_id uuid
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT *
  FROM private.admin_launch_battle_campaign(p_campaign_id);
$$;

REVOKE ALL ON FUNCTION private.admin_launch_battle_campaign(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_launch_battle_campaign(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_launch_battle_campaign(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_launch_battle_campaign(uuid) TO authenticated, service_role;

ALTER FUNCTION public.admin_validate_battle(uuid) SET SCHEMA private;

CREATE FUNCTION public.admin_validate_battle(p_battle_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.admin_validate_battle(p_battle_id);
$$;

REVOKE ALL ON FUNCTION private.admin_validate_battle(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_validate_battle(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.admin_validate_battle(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_validate_battle(uuid) TO authenticated, service_role;

ALTER FUNCTION public.can_create_active_battle(uuid) SET SCHEMA private;

CREATE FUNCTION public.can_create_active_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.can_create_active_battle(p_user_id);
$$;

REVOKE ALL ON FUNCTION private.can_create_active_battle(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_create_active_battle(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.can_create_active_battle(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_create_active_battle(uuid) TO authenticated, service_role;

ALTER FUNCTION public.can_create_battle(uuid) SET SCHEMA private;

CREATE FUNCTION public.can_create_battle(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.can_create_battle(p_user_id);
$$;

REVOKE ALL ON FUNCTION private.can_create_battle(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_create_battle(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.can_create_battle(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_create_battle(uuid) TO authenticated, service_role;

ALTER FUNCTION public.check_battle_pair_active(uuid, uuid) SET SCHEMA private;

CREATE FUNCTION public.check_battle_pair_active(
  p_producer_a uuid,
  p_producer_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.check_battle_pair_active(p_producer_a, p_producer_b);
$$;

REVOKE ALL ON FUNCTION private.check_battle_pair_active(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_battle_pair_active(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.check_battle_pair_active(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.check_battle_pair_active(uuid, uuid) TO authenticated, service_role;

ALTER FUNCTION public.enqueue_loudness_normalization_backfill() SET SCHEMA private;

CREATE FUNCTION public.enqueue_loudness_normalization_backfill()
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.enqueue_loudness_normalization_backfill();
$$;

REVOKE ALL ON FUNCTION private.enqueue_loudness_normalization_backfill() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enqueue_loudness_normalization_backfill() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.enqueue_loudness_normalization_backfill() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_loudness_normalization_backfill() TO authenticated, service_role;

ALTER FUNCTION public.get_battle_pair_cooldown_end(uuid, uuid) SET SCHEMA private;

CREATE FUNCTION public.get_battle_pair_cooldown_end(
  p_producer_a uuid,
  p_producer_b uuid
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.get_battle_pair_cooldown_end(p_producer_a, p_producer_b);
$$;

REVOKE ALL ON FUNCTION private.get_battle_pair_cooldown_end(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_battle_pair_cooldown_end(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_battle_pair_cooldown_end(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_battle_pair_cooldown_end(uuid, uuid) TO authenticated, service_role;

ALTER FUNCTION public.get_loser_share_data(uuid) SET SCHEMA private;

CREATE FUNCTION public.get_loser_share_data(p_battle_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.get_loser_share_data(p_battle_id);
$$;

REVOKE ALL ON FUNCTION private.get_loser_share_data(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_loser_share_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_loser_share_data(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_loser_share_data(uuid) TO authenticated, service_role;

ALTER FUNCTION public.get_my_trial_status() SET SCHEMA private;

CREATE FUNCTION public.get_my_trial_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.get_my_trial_status();
$$;

REVOKE ALL ON FUNCTION private.get_my_trial_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_trial_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_my_trial_status() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_trial_status() TO authenticated, service_role;

ALTER FUNCTION public.get_user_battle_quota(uuid) SET SCHEMA private;

CREATE FUNCTION public.get_user_battle_quota(p_user_id uuid)
RETURNS TABLE (
  tier text,
  used_this_month bigint,
  battle_limit integer,
  remaining_this_month integer,
  can_create boolean,
  reason text,
  reset_at timestamptz
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT *
  FROM private.get_user_battle_quota(p_user_id);
$$;

REVOKE ALL ON FUNCTION private.get_user_battle_quota(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_user_battle_quota(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_user_battle_quota(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_battle_quota(uuid) TO authenticated, service_role;

ALTER FUNCTION public.record_loser_battle_share(uuid, text, text) SET SCHEMA private;

CREATE FUNCTION public.record_loser_battle_share(
  p_battle_id uuid,
  p_share_channel text,
  p_template_used text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.record_loser_battle_share(p_battle_id, p_share_channel, p_template_used);
$$;

REVOKE ALL ON FUNCTION private.record_loser_battle_share(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_loser_battle_share(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.record_loser_battle_share(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_loser_battle_share(uuid, text, text) TO authenticated, service_role;

ALTER FUNCTION public.rpc_create_battle(text, text, uuid, text, uuid, uuid, text, uuid) SET SCHEMA private;

CREATE FUNCTION public.rpc_create_battle(
  p_title text,
  p_slug text,
  p_producer2_id uuid,
  p_description text DEFAULT NULL,
  p_product1_id uuid DEFAULT NULL,
  p_product2_id uuid DEFAULT NULL,
  p_battle_type text DEFAULT 'user',
  p_genre_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT private.rpc_create_battle(
    p_title,
    p_slug,
    p_producer2_id,
    p_description,
    p_product1_id,
    p_product2_id,
    p_battle_type,
    p_genre_id
  );
$$;

REVOKE ALL ON FUNCTION private.rpc_create_battle(text, text, uuid, text, uuid, uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_create_battle(text, text, uuid, text, uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.rpc_create_battle(text, text, uuid, text, uuid, uuid, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_create_battle(text, text, uuid, text, uuid, uuid, text, uuid) TO authenticated, service_role;

-- Trigger functions do not need public wrappers. Existing triggers keep their
-- function OID when the implementation is moved to the private schema.
ALTER FUNCTION public.notify_battle_users_on_status_change() SET SCHEMA private;
REVOKE ALL ON FUNCTION private.notify_battle_users_on_status_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.notify_battle_users_on_status_change() FROM anon;
REVOKE ALL ON FUNCTION private.notify_battle_users_on_status_change() FROM authenticated;
GRANT EXECUTE ON FUNCTION private.notify_battle_users_on_status_change() TO service_role;

ALTER FUNCTION public.notify_forum_topic_author_on_reply() SET SCHEMA private;
REVOKE ALL ON FUNCTION private.notify_forum_topic_author_on_reply() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.notify_forum_topic_author_on_reply() FROM anon;
REVOKE ALL ON FUNCTION private.notify_forum_topic_author_on_reply() FROM authenticated;
GRANT EXECUTE ON FUNCTION private.notify_forum_topic_author_on_reply() TO service_role;

COMMIT;
