BEGIN;

DROP VIEW IF EXISTS public.battle_of_the_day;
DROP FUNCTION IF EXISTS private._view_battle_of_the_day();

CREATE OR REPLACE FUNCTION private._view_battle_of_the_day()
RETURNS TABLE (
  battle_id uuid,
  slug text,
  title text,
  status public.battle_status,
  producer1_id uuid,
  producer1_username text,
  producer2_id uuid,
  producer2_username text,
  winner_id uuid,
  votes_today integer,
  votes_total integer,
  producer1_avatar_url text,
  producer2_avatar_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
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
    r.votes_total,
    p1.avatar_url AS producer1_avatar_url,
    p2.avatar_url AS producer2_avatar_url
  FROM ranked r
  LEFT JOIN public.public_producer_profiles p1 ON p1.user_id = r.producer1_id
  LEFT JOIN public.public_producer_profiles p2 ON p2.user_id = r.producer2_id
  WHERE r.rn = 1;
$$;

REVOKE EXECUTE ON FUNCTION private._view_battle_of_the_day() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private._view_battle_of_the_day() TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.battle_of_the_day
WITH (security_invoker = true)
AS
SELECT * FROM private._view_battle_of_the_day();

REVOKE ALL ON TABLE public.battle_of_the_day FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.battle_of_the_day TO anon, authenticated, service_role;

COMMIT;
