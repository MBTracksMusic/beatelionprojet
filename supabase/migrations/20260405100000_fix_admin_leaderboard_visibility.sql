/*
  # Fix: admin exclusion from all leaderboards

  Context:
    Migration 090000 was deployed with an intermediate version that still included
    OR up.role = 'admin' and role IN ('producer', 'admin') in visibility conditions.
    Subsequent edits to the local file were never applied because Supabase does not
    re-run already-recorded migrations.

  This migration applies the final corrections:
    - role IN ('producer', 'admin')  →  role = 'producer'
    - OR up.role = 'admin'           →  removed everywhere

  Objects updated:
    1. get_leaderboard_producers()
    2. season_leaderboard VIEW       (dropped before leaderboard_producers)
    3. leaderboard_producers VIEW    (rebuilt)
    4. season_leaderboard VIEW       (recreated)
    5. weekly_leaderboard VIEW
    6. suggest_opponents()
    7. reset_elo_for_new_season()
    8. get_public_home_top_producers()
*/

BEGIN;

-- ===========================================================================
-- 1. get_leaderboard_producers()
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_leaderboard_producers()
RETURNS TABLE (
  user_id       uuid,
  username      text,
  avatar_url    text,
  producer_tier public.producer_tier_type,
  elo_rating    integer,
  battle_wins   integer,
  battle_losses integer,
  battle_draws  integer,
  total_battles integer,
  win_rate      numeric,
  rank_position bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
  FROM base b;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard_producers() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_leaderboard_producers() FROM anon;
REVOKE ALL ON FUNCTION public.get_leaderboard_producers() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_leaderboard_producers() TO anon;
GRANT EXECUTE ON FUNCTION public.get_leaderboard_producers() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_leaderboard_producers() TO service_role;


-- ===========================================================================
-- 2. Drop season_leaderboard first (depends on leaderboard_producers)
-- ===========================================================================

DROP VIEW IF EXISTS public.season_leaderboard;


-- ===========================================================================
-- 3. Rebuild leaderboard_producers VIEW
-- ===========================================================================

DROP VIEW IF EXISTS public.leaderboard_producers;
CREATE VIEW public.leaderboard_producers
WITH (security_invoker = true)
AS
SELECT *
FROM public.get_leaderboard_producers()
ORDER BY rank_position ASC;

REVOKE ALL ON TABLE public.leaderboard_producers FROM PUBLIC;
REVOKE ALL ON TABLE public.leaderboard_producers FROM anon;
REVOKE ALL ON TABLE public.leaderboard_producers FROM authenticated;
GRANT SELECT ON TABLE public.leaderboard_producers TO anon;
GRANT SELECT ON TABLE public.leaderboard_producers TO authenticated;
GRANT SELECT ON TABLE public.leaderboard_producers TO service_role;


-- ===========================================================================
-- 4. Recreate season_leaderboard VIEW
-- ===========================================================================

CREATE VIEW public.season_leaderboard
WITH (security_invoker = true)
AS
WITH active AS (
  SELECT cs.id, cs.name, cs.start_date, cs.end_date
  FROM public.competitive_seasons cs
  WHERE cs.is_active = true
  ORDER BY cs.start_date DESC
  LIMIT 1
)
SELECT
  a.id AS season_id,
  a.name AS season_name,
  a.start_date,
  a.end_date,
  lp.user_id,
  lp.username,
  lp.avatar_url,
  lp.producer_tier,
  lp.elo_rating,
  lp.battle_wins,
  lp.battle_losses,
  lp.battle_draws,
  lp.total_battles,
  lp.win_rate,
  lp.rank_position
FROM active a
JOIN public.leaderboard_producers lp ON true
ORDER BY lp.rank_position ASC;

REVOKE ALL ON TABLE public.season_leaderboard FROM PUBLIC;
REVOKE ALL ON TABLE public.season_leaderboard FROM anon;
REVOKE ALL ON TABLE public.season_leaderboard FROM authenticated;
GRANT SELECT ON TABLE public.season_leaderboard TO anon;
GRANT SELECT ON TABLE public.season_leaderboard TO authenticated;
GRANT SELECT ON TABLE public.season_leaderboard TO service_role;


-- ===========================================================================
-- 5. weekly_leaderboard VIEW
-- ===========================================================================

DROP VIEW IF EXISTS public.weekly_leaderboard;
CREATE VIEW public.weekly_leaderboard
WITH (security_invoker = true)
AS
WITH recent_battles AS (
  SELECT b.id, b.producer1_id, b.producer2_id, b.winner_id
  FROM public.battles b
  WHERE b.status = 'completed'
    AND b.updated_at >= now() - interval '7 days'
),
participants AS (
  SELECT
    rb.producer1_id AS user_id,
    CASE WHEN rb.winner_id = rb.producer1_id THEN 1 ELSE 0 END AS win,
    CASE WHEN rb.winner_id IS NOT NULL AND rb.winner_id <> rb.producer1_id THEN 1 ELSE 0 END AS loss
  FROM recent_battles rb WHERE rb.producer1_id IS NOT NULL
  UNION ALL
  SELECT
    rb.producer2_id AS user_id,
    CASE WHEN rb.winner_id = rb.producer2_id THEN 1 ELSE 0 END AS win,
    CASE WHEN rb.winner_id IS NOT NULL AND rb.winner_id <> rb.producer2_id THEN 1 ELSE 0 END AS loss
  FROM recent_battles rb WHERE rb.producer2_id IS NOT NULL
),
agg AS (
  SELECT p.user_id,
    SUM(p.win)::integer AS weekly_wins,
    SUM(p.loss)::integer AS weekly_losses
  FROM participants p
  GROUP BY p.user_id
)
SELECT
  up.id AS user_id,
  up.username,
  a.weekly_wins,
  a.weekly_losses,
  CASE
    WHEN (a.weekly_wins + a.weekly_losses) = 0 THEN 0::numeric
    ELSE round((a.weekly_wins::numeric / (a.weekly_wins + a.weekly_losses)::numeric) * 100, 2)
  END AS weekly_winrate,
  row_number() OVER (
    ORDER BY a.weekly_wins DESC, a.weekly_losses ASC, up.username ASC NULLS LAST, up.id ASC
  ) AS rank_position
FROM agg a
JOIN public.user_profiles up ON up.id = a.user_id
LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
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
ORDER BY rank_position ASC;

REVOKE ALL ON TABLE public.weekly_leaderboard FROM PUBLIC;
REVOKE ALL ON TABLE public.weekly_leaderboard FROM anon;
REVOKE ALL ON TABLE public.weekly_leaderboard FROM authenticated;
GRANT SELECT ON TABLE public.weekly_leaderboard TO anon;
GRANT SELECT ON TABLE public.weekly_leaderboard TO authenticated;
GRANT SELECT ON TABLE public.weekly_leaderboard TO service_role;


-- ===========================================================================
-- 6. suggest_opponents()
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.suggest_opponents(p_user_id uuid)
RETURNS TABLE (
  user_id       uuid,
  username      text,
  avatar_url    text,
  producer_tier public.producer_tier_type,
  elo_rating    integer,
  battle_wins   integer,
  battle_losses integer,
  battle_draws  integer,
  elo_diff      integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor       uuid := auth.uid();
  v_jwt_role    text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_user_rating integer := 1200;
BEGIN
  IF p_user_id IS NULL THEN RETURN; END IF;

  IF NOT (
    v_jwt_role = 'service_role'
    OR (v_actor IS NOT NULL AND v_actor = p_user_id)
    OR public.is_admin(v_actor)
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(up.elo_rating, 1200) INTO v_user_rating
  FROM public.user_profiles up WHERE up.id = p_user_id LIMIT 1;

  IF NOT FOUND THEN RETURN; END IF;

  -- Tier 1: ±400
  RETURN QUERY
  SELECT up.id, up.username, up.avatar_url, up.producer_tier,
    COALESCE(up.elo_rating, 1200), COALESCE(up.battle_wins, 0),
    COALESCE(up.battle_losses, 0), COALESCE(up.battle_draws, 0),
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer
  FROM public.user_profiles up
  LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
  WHERE up.id <> p_user_id
    AND up.role = 'producer'
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL AND up.founding_trial_start IS NOT NULL
        AND pc.is_active = true AND now() < up.founding_trial_start + pc.trial_duration
      )
    )
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 400
  ORDER BY ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC, up.username ASC NULLS LAST
  LIMIT 10;
  IF FOUND THEN RETURN; END IF;

  -- Tier 2: ±600
  RETURN QUERY
  SELECT up.id, up.username, up.avatar_url, up.producer_tier,
    COALESCE(up.elo_rating, 1200), COALESCE(up.battle_wins, 0),
    COALESCE(up.battle_losses, 0), COALESCE(up.battle_draws, 0),
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer
  FROM public.user_profiles up
  LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
  WHERE up.id <> p_user_id
    AND up.role = 'producer'
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL AND up.founding_trial_start IS NOT NULL
        AND pc.is_active = true AND now() < up.founding_trial_start + pc.trial_duration
      )
    )
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 600
  ORDER BY ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC, up.username ASC NULLS LAST
  LIMIT 10;
  IF FOUND THEN RETURN; END IF;

  -- Tier 3: ±800
  RETURN QUERY
  SELECT up.id, up.username, up.avatar_url, up.producer_tier,
    COALESCE(up.elo_rating, 1200), COALESCE(up.battle_wins, 0),
    COALESCE(up.battle_losses, 0), COALESCE(up.battle_draws, 0),
    ABS(COALESCE(up.elo_rating, 1200) - v_user_rating)::integer
  FROM public.user_profiles up
  LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
  WHERE up.id <> p_user_id
    AND up.role = 'producer'
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL AND up.founding_trial_start IS NOT NULL
        AND pc.is_active = true AND now() < up.founding_trial_start + pc.trial_duration
      )
    )
    AND ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) <= 800
  ORDER BY ABS(COALESCE(up.elo_rating, 1200) - v_user_rating) ASC,
    COALESCE(up.elo_rating, 1200) DESC, up.username ASC NULLS LAST
  LIMIT 10;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.suggest_opponents(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.suggest_opponents(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.suggest_opponents(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggest_opponents(uuid) TO service_role;


-- ===========================================================================
-- 7. reset_elo_for_new_season()
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.reset_elo_for_new_season()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor         uuid    := auth.uid();
  v_jwt_role      text    := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_active_season uuid;
  v_expected      integer := 0;
  v_archived      integer := 0;
  v_updated       integer := 0;
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  v_active_season := public.get_active_season();
  IF v_active_season IS NULL THEN RAISE EXCEPTION 'no_active_season'; END IF;

  RAISE LOG '[season] reset_elo_for_new_season: starting archive for season %', v_active_season;

  SELECT COUNT(*)::integer INTO v_expected FROM public.leaderboard_producers;

  INSERT INTO public.season_results (season_id, user_id, final_elo, rank_position, wins, losses)
  SELECT v_active_season, lp.user_id, lp.elo_rating, lp.rank_position::integer, lp.battle_wins, lp.battle_losses
  FROM public.leaderboard_producers lp
  ON CONFLICT (season_id, user_id) DO UPDATE SET
    final_elo = EXCLUDED.final_elo, rank_position = EXCLUDED.rank_position,
    wins = EXCLUDED.wins, losses = EXCLUDED.losses, created_at = now();

  GET DIAGNOSTICS v_archived = ROW_COUNT;
  RAISE LOG '[season] reset_elo_for_new_season: archived % / % producers for season %', v_archived, v_expected, v_active_season;

  IF v_expected > 0 AND v_archived = 0 THEN
    RAISE EXCEPTION 'season_archive_failed: leaderboard had % producers but 0 rows were archived for season %', v_expected, v_active_season;
  END IF;

  INSERT INTO public.user_badges (user_id, badge_id)
  SELECT sr.user_id, pb.id FROM public.season_results sr
  JOIN public.producer_badges pb ON pb.name = 'Season Champion'
  WHERE sr.season_id = v_active_season AND sr.rank_position = 1
  ON CONFLICT DO NOTHING;

  INSERT INTO public.user_badges (user_id, badge_id)
  SELECT sr.user_id, pb.id FROM public.season_results sr
  JOIN public.producer_badges pb ON pb.name = 'Top 10 Season'
  WHERE sr.season_id = v_active_season AND sr.rank_position <= 10
  ON CONFLICT DO NOTHING;

  INSERT INTO public.user_badges (user_id, badge_id)
  SELECT sr.user_id, pb.id FROM public.season_results sr
  JOIN public.producer_badges pb ON pb.name = 'Top 100 Season'
  WHERE sr.season_id = v_active_season AND sr.rank_position <= 100
  ON CONFLICT DO NOTHING;

  UPDATE public.user_profiles up
  SET elo_rating = GREATEST(100, round(1200 + ((COALESCE(up.elo_rating, 1200) - 1200) * 0.5))::integer),
      updated_at = now()
  WHERE up.role = 'producer'
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL
        AND up.founding_trial_start IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.producer_campaigns pc
          WHERE pc.type = up.producer_campaign_type
            AND pc.is_active = true
            AND now() < up.founding_trial_start + pc.trial_duration
        )
      )
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE LOG '[season] reset_elo_for_new_season: ELO reset applied to % producers for season %', v_updated, v_active_season;
  RETURN v_updated;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.reset_elo_for_new_season() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reset_elo_for_new_season() FROM anon;
REVOKE EXECUTE ON FUNCTION public.reset_elo_for_new_season() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.reset_elo_for_new_season() TO service_role;
GRANT EXECUTE ON FUNCTION public.reset_elo_for_new_season() TO authenticated;


-- ===========================================================================
-- 8. get_public_home_top_producers()
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_public_home_top_producers(p_limit integer DEFAULT 10)
RETURNS TABLE (
  user_id      uuid,
  raw_username text,
  username     text,
  avatar_url   text,
  wins         integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH wins_by_user AS (
    SELECT b.winner_id AS user_id, COUNT(*)::integer AS wins
    FROM public.battles b
    WHERE b.status = 'completed' AND b.winner_id IS NOT NULL
    GROUP BY b.winner_id
  )
  SELECT
    up.id AS user_id,
    up.username AS raw_username,
    public.get_public_profile_label(up) AS username,
    CASE
      WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL
      ELSE up.avatar_url
    END AS avatar_url,
    w.wins
  FROM wins_by_user w
  JOIN public.user_profiles up ON up.id = w.user_id
  LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
  WHERE up.role = 'producer'
    AND NULLIF(btrim(COALESCE(up.username, '')), '') IS NOT NULL
    AND (
      up.is_producer_active = true
      OR (
        up.producer_campaign_type IS NOT NULL
        AND up.founding_trial_start IS NOT NULL
        AND pc.is_active = true
        AND now() < up.founding_trial_start + pc.trial_duration
      )
    )
  ORDER BY w.wins DESC, up.updated_at DESC, up.id ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 30);
$$;

REVOKE ALL ON FUNCTION public.get_public_home_top_producers(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_home_top_producers(integer) FROM anon;
REVOKE ALL ON FUNCTION public.get_public_home_top_producers(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_top_producers(integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_home_top_producers(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_top_producers(integer) TO service_role;

COMMIT;
