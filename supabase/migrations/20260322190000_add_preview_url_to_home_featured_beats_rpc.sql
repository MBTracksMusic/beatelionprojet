BEGIN;

DROP FUNCTION IF EXISTS public.get_public_home_featured_beats(integer);

CREATE FUNCTION public.get_public_home_featured_beats(p_limit integer DEFAULT 10)
RETURNS TABLE (
  id uuid,
  title text,
  slug text,
  price integer,
  play_count integer,
  cover_image_url text,
  preview_url text,
  is_sold boolean,
  producer_id uuid,
  producer_username text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p.id,
    p.title,
    p.slug,
    p.price,
    COALESCE(p.play_count, 0) AS play_count,
    p.cover_image_url,
    NULLIF(TRIM(p.preview_url), '') AS preview_url,
    COALESCE(p.is_sold, false) AS is_sold,
    p.producer_id,
    public.get_public_profile_label(up) AS producer_username
  FROM public.products p
  LEFT JOIN public.user_profiles up ON up.id = p.producer_id
  WHERE p.product_type = 'beat'
    AND p.deleted_at IS NULL
    AND p.status = 'active'
    AND COALESCE(p.is_published, false) = true
  ORDER BY COALESCE(p.play_count, 0) DESC, p.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 24);
$$;

COMMENT ON FUNCTION public.get_public_home_featured_beats(integer)
IS 'Public-safe featured beats feed for homepage discovery.';

REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM anon;
REVOKE ALL ON FUNCTION public.get_public_home_featured_beats(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_home_featured_beats(integer) TO service_role;

COMMIT;
