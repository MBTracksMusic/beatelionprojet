/*
  # Add forum category stats RPC

  Goal:
  - return category rows with aggregated topic/post counts directly from SQL
  - preserve forum RLS behavior by using SECURITY INVOKER
  - avoid loading all topics in the frontend only to count them in JS
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.get_forum_categories_with_stats()
RETURNS TABLE (
  id uuid,
  name text,
  slug text,
  description text,
  is_premium_only boolean,
  "position" integer,
  xp_multiplier numeric,
  moderation_strictness text,
  is_competitive boolean,
  required_rank_tier text,
  allow_links boolean,
  allow_media boolean,
  created_at timestamptz,
  topic_count integer,
  post_count integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT
    fc.id,
    fc.name,
    fc.slug,
    fc.description,
    fc.is_premium_only,
    fc.position,
    fc.xp_multiplier,
    fc.moderation_strictness,
    fc.is_competitive,
    fc.required_rank_tier,
    fc.allow_links,
    fc.allow_media,
    fc.created_at,
    COUNT(ft.id)::integer AS topic_count,
    COALESCE(SUM(ft.post_count), 0)::integer AS post_count
  FROM public.forum_categories fc
  LEFT JOIN public.forum_topics ft
    ON ft.category_id = fc.id
  GROUP BY
    fc.id,
    fc.name,
    fc.slug,
    fc.description,
    fc.is_premium_only,
    fc.position,
    fc.xp_multiplier,
    fc.moderation_strictness,
    fc.is_competitive,
    fc.required_rank_tier,
    fc.allow_links,
    fc.allow_media,
    fc.created_at
  ORDER BY fc.position ASC, fc.created_at ASC;
$$;

REVOKE ALL ON FUNCTION public.get_forum_categories_with_stats() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_forum_categories_with_stats() FROM anon;
REVOKE ALL ON FUNCTION public.get_forum_categories_with_stats() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_forum_categories_with_stats() TO anon;
GRANT EXECUTE ON FUNCTION public.get_forum_categories_with_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_forum_categories_with_stats() TO service_role;

COMMIT;
