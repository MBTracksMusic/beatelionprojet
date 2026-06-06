/*
  # Wrap reputation leaderboard RPC outside the exposed schema

  Supabase Security Advisor flags public SECURITY DEFINER functions that are
  executable by authenticated users through PostgREST RPC.

  rpc_get_leaderboard must stay callable by signed-in users and must keep its
  existing SECURITY DEFINER implementation because the calculation reads
  reputation_events across users while direct RLS only exposes a user's own
  events. Preserve the public RPC signature and business query by moving the
  privileged implementation to private, then exposing a SECURITY INVOKER public
  wrapper with the same return shape and grants.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

/*
  Older wrapper migrations may already have a private implementation with the
  same signature. The latest public implementation includes admin exclusion, so
  drop the stale private copy before moving the current public function.
*/
DROP FUNCTION IF EXISTS private.rpc_get_leaderboard(text, text, integer);

ALTER FUNCTION public.rpc_get_leaderboard(text, text, integer) SET SCHEMA private;

CREATE FUNCTION public.rpc_get_leaderboard(
  p_period text DEFAULT 'week',
  p_source text DEFAULT 'overall',
  p_limit integer DEFAULT 10
)
RETURNS TABLE (
  user_id uuid,
  username text,
  avatar_url text,
  producer_tier public.producer_tier_type,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  period_xp bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, private, pg_temp
AS $$
  SELECT *
  FROM private.rpc_get_leaderboard(p_period, p_source, p_limit);
$$;

REVOKE ALL ON FUNCTION private.rpc_get_leaderboard(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.rpc_get_leaderboard(text, text, integer) FROM anon;
REVOKE ALL ON FUNCTION private.rpc_get_leaderboard(text, text, integer) FROM authenticated;

REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM authenticated;

GRANT EXECUTE ON FUNCTION private.rpc_get_leaderboard(text, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_get_leaderboard(text, text, integer) TO authenticated, service_role;

COMMENT ON FUNCTION public.rpc_get_leaderboard(text, text, integer) IS
  'SECURITY INVOKER wrapper for the private reputation leaderboard implementation.';

COMMIT;
