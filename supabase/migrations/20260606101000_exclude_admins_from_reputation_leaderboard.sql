/*
  # Exclude admins from public reputation leaderboard

  The public ELO, weekly, and season leaderboards already exclude admin accounts
  through producer-only views. The reputation leaderboard uses a separate RPC and
  previously returned any profile with a username, including admins.

  Keep admin reputation data intact for the admin dashboard, but remove admin
  accounts from the public leaderboard calculation before ordering and limiting.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.rpc_get_leaderboard(
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
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH params AS (
    SELECT
      CASE lower(COALESCE(p_period, 'week'))
        WHEN 'month' THEN now() - interval '30 days'
        ELSE now() - interval '7 days'
      END AS period_start,
      CASE lower(COALESCE(p_source, 'overall'))
        WHEN 'forum' THEN 'forum'
        WHEN 'battle' THEN 'battles'
        WHEN 'battles' THEN 'battles'
        WHEN 'commerce' THEN 'commerce'
        ELSE 'overall'
      END AS source_filter,
      GREATEST(1, LEAST(COALESCE(p_limit, 10), 100)) AS row_limit
  ),
  event_scores AS (
    SELECT
      re.user_id,
      COALESCE(sum(re.delta_xp), 0)::bigint AS period_xp
    FROM public.reputation_events re
    CROSS JOIN params p
    WHERE re.created_at >= p.period_start
      AND (
        p.source_filter = 'overall'
        OR re.source = p.source_filter
      )
    GROUP BY re.user_id
  )
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    ur.xp,
    ur.level,
    ur.rank_tier,
    ur.forum_xp,
    ur.battle_xp,
    ur.commerce_xp,
    ur.reputation_score,
    COALESCE(es.period_xp, 0) AS period_xp
  FROM public.user_reputation ur
  JOIN public.user_profiles up ON up.id = ur.user_id
  LEFT JOIN event_scores es ON es.user_id = ur.user_id
  CROSS JOIN params p
  WHERE up.username IS NOT NULL
    AND up.role <> 'admin'::public.user_role
  ORDER BY
    COALESCE(es.period_xp, 0) DESC,
    CASE p.source_filter
      WHEN 'forum' THEN ur.forum_xp
      WHEN 'battles' THEN ur.battle_xp
      WHEN 'commerce' THEN ur.commerce_xp
      ELSE ur.xp
    END DESC,
    ur.xp DESC,
    up.created_at ASC
  LIMIT (SELECT row_limit FROM params);
$$;

REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_leaderboard(text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_leaderboard(text, text, integer) TO service_role;

COMMIT;
