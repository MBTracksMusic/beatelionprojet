/*
  # Replace public projection RPC execution with filtered views

  These objects expose public catalogue/profile/leaderboard data. The public
  access is intentional, but direct EXECUTE on SECURITY DEFINER RPCs creates
  Supabase linter warnings. This migration keeps the same public projections
  as views and removes anon/authenticated EXECUTE from the underlying RPCs.

  The views remain column allowlists. They do not grant direct access to
  user_profiles, battle_votes, battles, or producer_campaigns.
*/

BEGIN;

CREATE OR REPLACE VIEW public.public_producer_profiles
WITH (security_invoker = false)
AS
SELECT
  up.id AS user_id,
  public.get_public_profile_label(up) AS username,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
    ELSE up.avatar_url
  END AS avatar_url,
  up.producer_tier,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
    ELSE up.bio
  END AS bio,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN '{}'::jsonb
    ELSE COALESCE(up.social_links, '{}'::jsonb)
  END AS social_links,
  COALESCE(ur.xp, 0) AS xp,
  COALESCE(ur.level, 1) AS level,
  COALESCE(ur.rank_tier, 'bronze') AS rank_tier,
  COALESCE(ur.reputation_score, 0) AS reputation_score,
  up.created_at,
  up.updated_at,
  up.username AS raw_username,
  (COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL) AS is_deleted,
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM public.producer_subscriptions ps_any
      WHERE ps_any.user_id = up.id
    ) THEN EXISTS (
      SELECT 1
      FROM public.producer_subscriptions ps
      WHERE ps.user_id = up.id
        AND COALESCE(ps.is_producer_active, false) = true
        AND ps.subscription_status IN ('active', 'trialing')
        AND ps.current_period_end > now()
    )
    ELSE COALESCE(up.is_producer_active, false)
  END AS is_producer_active
FROM public.user_profiles up
LEFT JOIN public.user_reputation ur ON ur.user_id = up.id
WHERE NULLIF(btrim(COALESCE(up.username, '')), '') IS NOT NULL
  AND up.role = 'producer';

CREATE OR REPLACE VIEW public.public_producer_profiles_v2
WITH (security_invoker = false)
AS
SELECT
  up.id AS user_id,
  up.username,
  up.avatar_url,
  up.producer_tier,
  up.bio,
  up.social_links,
  up.created_at,
  up.updated_at
FROM public.user_profiles up
WHERE up.is_producer_active = true
  AND up.role = 'producer';

CREATE OR REPLACE VIEW public.public_visible_producer_profiles
WITH (security_invoker = false)
AS
SELECT
  up.id AS user_id,
  up.username AS raw_username,
  public.get_public_profile_label(up) AS username,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
    ELSE up.avatar_url
  END AS avatar_url,
  up.producer_tier,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
    ELSE up.bio
  END AS bio,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN '{}'::jsonb
    ELSE COALESCE(up.social_links, '{}'::jsonb)
  END AS social_links,
  COALESCE(ur.xp, 0) AS xp,
  COALESCE(ur.level, 1) AS level,
  COALESCE(ur.rank_tier, 'bronze') AS rank_tier,
  COALESCE(ur.reputation_score, 0) AS reputation_score,
  (COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL) AS is_deleted,
  (
    COALESCE(up.is_producer_active, false) = true
    OR (
      up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND now() < up.founding_trial_start + interval '3 months'
    )
  ) AS is_producer_active,
  up.created_at,
  up.updated_at
FROM public.user_profiles up
LEFT JOIN public.user_reputation ur ON ur.user_id = up.id
WHERE NULLIF(btrim(COALESCE(up.username, '')), '') IS NOT NULL
  AND COALESCE(up.is_deleted, false) = false
  AND up.deleted_at IS NULL
  AND up.role = 'producer'
  AND (
    COALESCE(up.is_producer_active, false) = true
    OR (
      up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND now() < up.founding_trial_start + interval '3 months'
    )
    OR up.producer_tier IS NOT NULL
    OR EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.producer_id = up.id
        AND p.deleted_at IS NULL
        AND p.status = 'active'
        AND p.is_published = true
    )
    OR EXISTS (
      SELECT 1
      FROM public.battles b
      WHERE b.status IN ('active', 'voting', 'completed')
        AND (b.producer1_id = up.id OR b.producer2_id = up.id)
    )
  );

CREATE OR REPLACE VIEW public.forum_public_profiles_public
WITH (security_invoker = false)
AS
SELECT
  up.id AS user_id,
  public.get_public_profile_label(up) AS username,
  CASE
    WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
    ELSE up.avatar_url
  END AS avatar_url,
  COALESCE(ur.rank_tier, 'bronze')::text AS rank,
  COALESCE(ur.reputation_score, 0) AS reputation
FROM public.user_profiles up
LEFT JOIN public.user_reputation ur ON ur.user_id = up.id
WHERE NULLIF(btrim(COALESCE(up.username, '')), '') IS NOT NULL;

CREATE OR REPLACE VIEW public.leaderboard_producers
WITH (security_invoker = false)
AS
WITH base AS (
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    COALESCE(up.elo_rating, 1200) AS elo_rating,
    COALESCE(up.battle_wins, 0) AS battle_wins,
    COALESCE(up.battle_losses, 0) AS battle_losses,
    COALESCE(up.battle_draws, 0) AS battle_draws,
    (
      COALESCE(up.battle_wins, 0)
      + COALESCE(up.battle_losses, 0)
      + COALESCE(up.battle_draws, 0)
    )::integer AS total_battles
  FROM public.user_profiles up
  LEFT JOIN public.producer_campaigns pc
    ON pc.type = up.producer_campaign_type
  WHERE up.role = 'producer'
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL
        AND up.founding_trial_start IS NOT NULL
        AND pc.is_active = true
        AND now() < up.founding_trial_start + pc.trial_duration
      )
    )
)
SELECT
  b.user_id,
  b.username,
  b.avatar_url,
  b.producer_tier,
  b.elo_rating,
  b.battle_wins,
  b.battle_losses,
  b.battle_draws,
  b.total_battles,
  CASE
    WHEN b.total_battles = 0 THEN 0::numeric
    ELSE round((b.battle_wins::numeric / b.total_battles::numeric) * 100, 2)
  END AS win_rate,
  row_number() OVER (
    ORDER BY
      b.elo_rating DESC,
      b.battle_wins DESC,
      b.battle_losses ASC,
      b.username ASC NULLS LAST,
      b.user_id ASC
  ) AS rank_position
FROM base b
ORDER BY rank_position ASC;

CREATE OR REPLACE VIEW public.battle_of_the_day
WITH (security_invoker = false)
AS
WITH daily_votes AS (
  SELECT
    bv.battle_id,
    count(*)::integer AS votes_today
  FROM public.battle_votes bv
  WHERE bv.created_at >= date_trunc('day', now())
    AND bv.created_at < date_trunc('day', now()) + interval '1 day'
  GROUP BY bv.battle_id
),
ranked AS (
  SELECT
    b.id AS battle_id,
    b.slug,
    b.title,
    b.status,
    b.producer1_id,
    b.producer2_id,
    b.winner_id,
    COALESCE(dv.votes_today, 0)::integer AS votes_today,
    (COALESCE(b.votes_producer1, 0) + COALESCE(b.votes_producer2, 0))::integer AS votes_total,
    row_number() OVER (
      ORDER BY
        COALESCE(dv.votes_today, 0) DESC,
        (COALESCE(b.votes_producer1, 0) + COALESCE(b.votes_producer2, 0)) DESC,
        b.updated_at DESC,
        b.id ASC
    ) AS rn
  FROM public.battles b
  LEFT JOIN daily_votes dv ON dv.battle_id = b.id
  WHERE b.status IN ('active', 'voting', 'completed')
)
SELECT
  r.battle_id,
  r.slug,
  r.title,
  r.status,
  r.producer1_id,
  p1.username AS producer1_username,
  r.producer2_id,
  p2.username AS producer2_username,
  r.winner_id,
  r.votes_today,
  r.votes_total
FROM ranked r
LEFT JOIN public.public_producer_profiles p1 ON p1.user_id = r.producer1_id
LEFT JOIN public.public_producer_profiles p2 ON p2.user_id = r.producer2_id
WHERE r.rn = 1;

REVOKE ALL ON TABLE public.public_producer_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.public_producer_profiles_v2 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.public_visible_producer_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.forum_public_profiles_public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.leaderboard_producers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.battle_of_the_day FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.public_producer_profiles TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.public_producer_profiles_v2 TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.public_visible_producer_profiles TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.forum_public_profiles_public TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.leaderboard_producers TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.battle_of_the_day TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_forum_public_profiles_public() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_leaderboard_producers() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_battle_of_the_day() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_producer_profiles() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_producer_profiles_soft() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_producer_profiles_v2() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_visible_producer_profiles() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_forum_public_profiles_public() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_leaderboard_producers() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_public_battle_of_the_day() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_public_producer_profiles() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_public_producer_profiles_soft() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_public_producer_profiles_v2() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_public_visible_producer_profiles() TO service_role;

COMMIT;
