/*
  # Producer top beats visibility priority

  Goals:
  - Compute a durable, public-safe performance score for beats.
  - Rank beats per producer.
  - Flag the producer top 10 beats.
  - Expose RPCs for producer-specific top beats and prioritized discovery.
  - Enrich the public catalog read model without changing write flows.
*/

BEGIN;

CREATE OR REPLACE VIEW public.producer_beats_ranked
WITH (security_invoker = true)
AS
WITH published_beats AS (
  SELECT
    p.id,
    p.producer_id,
    p.title,
    p.slug,
    p.cover_image_url,
    p.price,
    p.play_count,
    p.created_at,
    p.updated_at,
    COALESCE(p.status, 'active') AS status,
    COALESCE(p.is_published, false) AS is_published
  FROM public.products p
  WHERE p.product_type = 'beat'::public.product_type
    AND p.deleted_at IS NULL
    AND COALESCE(p.is_published, false) = true
    AND COALESCE(p.status, 'active') = 'active'
),
sales_by_product AS (
  SELECT
    pu.product_id,
    COUNT(*)::integer AS sales_count
  FROM public.purchases pu
  WHERE pu.status = 'completed'
  GROUP BY pu.product_id
),
battle_wins_by_product AS (
  SELECT
    winner_product_id AS product_id,
    COUNT(*)::integer AS battle_wins
  FROM (
    SELECT
      CASE
        WHEN b.winner_id = b.producer1_id THEN b.product1_id
        WHEN b.winner_id = b.producer2_id THEN b.product2_id
        ELSE NULL::uuid
      END AS winner_product_id
    FROM public.battles b
    WHERE b.status = 'completed'
      AND b.winner_id IS NOT NULL
  ) ranked_battles
  WHERE winner_product_id IS NOT NULL
  GROUP BY winner_product_id
),
scored AS (
  SELECT
    pb.id,
    pb.producer_id,
    pb.title,
    pb.slug,
    pb.cover_image_url,
    pb.price,
    pb.play_count,
    COALESCE(s.sales_count, 0) AS sales_count,
    COALESCE(w.battle_wins, 0) AS battle_wins,
    GREATEST(
      0,
      30 - FLOOR(EXTRACT(EPOCH FROM (now() - pb.created_at)) / 86400.0)::integer
    ) AS recency_bonus,
    (
      LEAST(COALESCE(pb.play_count, 0), 1000)
      + (COALESCE(s.sales_count, 0) * 25)
      + (COALESCE(w.battle_wins, 0) * 15)
      + GREATEST(
        0,
        30 - FLOOR(EXTRACT(EPOCH FROM (now() - pb.created_at)) / 86400.0)::integer
      )
    )::integer AS performance_score,
    (
      COALESCE(pb.play_count, 0)
      + COALESCE(s.sales_count, 0)
      + COALESCE(w.battle_wins, 0)
    )::integer AS engagement_count,
    pb.created_at,
    pb.updated_at
  FROM published_beats pb
  LEFT JOIN sales_by_product s
    ON s.product_id = pb.id
  LEFT JOIN battle_wins_by_product w
    ON w.product_id = pb.id
)
SELECT
  s.id,
  s.producer_id,
  s.title,
  s.slug,
  s.cover_image_url,
  s.price,
  s.play_count,
  s.sales_count,
  s.battle_wins,
  s.recency_bonus,
  s.performance_score,
  s.engagement_count,
  ROW_NUMBER() OVER (
    PARTITION BY s.producer_id
    ORDER BY s.performance_score DESC, s.sales_count DESC, s.battle_wins DESC, s.play_count DESC, s.created_at DESC, s.id ASC
  )::integer AS producer_rank,
  (
    s.engagement_count > 0
    AND ROW_NUMBER() OVER (
      PARTITION BY s.producer_id
      ORDER BY s.performance_score DESC, s.sales_count DESC, s.battle_wins DESC, s.play_count DESC, s.created_at DESC, s.id ASC
    ) <= 10
  ) AS top_10_flag,
  s.created_at,
  s.updated_at
FROM scored s;

COMMENT ON VIEW public.producer_beats_ranked
IS 'Ranks published active beats per producer using sales-first performance scoring.';

REVOKE ALL ON TABLE public.producer_beats_ranked FROM PUBLIC;
REVOKE ALL ON TABLE public.producer_beats_ranked FROM anon;
REVOKE ALL ON TABLE public.producer_beats_ranked FROM authenticated;
GRANT SELECT ON TABLE public.producer_beats_ranked TO anon;
GRANT SELECT ON TABLE public.producer_beats_ranked TO authenticated;
GRANT SELECT ON TABLE public.producer_beats_ranked TO service_role;

CREATE OR REPLACE FUNCTION public.get_producer_top_beats(p_producer_id uuid)
RETURNS TABLE (
  id uuid,
  producer_id uuid,
  title text,
  slug text,
  cover_image_url text,
  price integer,
  play_count integer,
  sales_count integer,
  battle_wins integer,
  recency_bonus integer,
  performance_score integer,
  producer_rank integer,
  top_10_flag boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    pbr.id,
    pbr.producer_id,
    pbr.title,
    pbr.slug,
    pbr.cover_image_url,
    pbr.price,
    pbr.play_count,
    pbr.sales_count,
    pbr.battle_wins,
    pbr.recency_bonus,
    pbr.performance_score,
    pbr.producer_rank,
    pbr.top_10_flag,
    pbr.created_at
  FROM public.producer_beats_ranked pbr
  WHERE pbr.producer_id = p_producer_id
    AND pbr.top_10_flag = true
  ORDER BY pbr.performance_score DESC, pbr.producer_rank ASC, pbr.created_at DESC
  LIMIT 10
$$;

COMMENT ON FUNCTION public.get_producer_top_beats(uuid)
IS 'Returns the public-safe top 10 ranked beats for a producer.';

REVOKE ALL ON FUNCTION public.get_producer_top_beats(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_producer_top_beats(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_producer_top_beats(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_producer_top_beats(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_producer_top_beats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_producer_top_beats(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.get_beats_with_priority()
RETURNS TABLE (
  id uuid,
  producer_id uuid,
  title text,
  slug text,
  cover_image_url text,
  price integer,
  play_count integer,
  sales_count integer,
  battle_wins integer,
  performance_score integer,
  producer_rank integer,
  top_10_flag boolean,
  priority_bucket integer,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    pbr.id,
    pbr.producer_id,
    pbr.title,
    pbr.slug,
    pbr.cover_image_url,
    pbr.price,
    pbr.play_count,
    pbr.sales_count,
    pbr.battle_wins,
    pbr.performance_score,
    pbr.producer_rank,
    pbr.top_10_flag,
    CASE WHEN pbr.top_10_flag THEN 0 ELSE 1 END AS priority_bucket,
    pbr.created_at
  FROM public.producer_beats_ranked pbr
  ORDER BY
    CASE WHEN pbr.top_10_flag THEN 0 ELSE 1 END ASC,
    pbr.performance_score DESC,
    pbr.created_at DESC
$$;

COMMENT ON FUNCTION public.get_beats_with_priority()
IS 'Returns public-safe ranked beats with producer-top-10 priority ordering.';

REVOKE ALL ON FUNCTION public.get_beats_with_priority() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_beats_with_priority() FROM anon;
REVOKE ALL ON FUNCTION public.get_beats_with_priority() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_beats_with_priority() TO anon;
GRANT EXECUTE ON FUNCTION public.get_beats_with_priority() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_beats_with_priority() TO service_role;

CREATE OR REPLACE FUNCTION public.get_public_home_featured_beats(p_limit integer DEFAULT 10)
RETURNS TABLE (
  id uuid,
  title text,
  slug text,
  price integer,
  play_count integer,
  cover_image_url text,
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
    COALESCE(p.is_sold, false) AS is_sold,
    p.producer_id,
    public.get_public_profile_label(up) AS producer_username
  FROM public.products p
  LEFT JOIN public.user_profiles up ON up.id = p.producer_id
  LEFT JOIN public.producer_beats_ranked pbr ON pbr.id = p.id
  WHERE p.product_type = 'beat'
    AND p.deleted_at IS NULL
    AND p.status = 'active'
    AND COALESCE(p.is_published, false) = true
  ORDER BY
    CASE WHEN COALESCE(pbr.top_10_flag, false) THEN 0 ELSE 1 END ASC,
    COALESCE(pbr.performance_score, 0) DESC,
    COALESCE(p.play_count, 0) DESC,
    p.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 24);
$$;

DO $$
DECLARE
  has_watermarked_path boolean;
  has_watermark_profile_id boolean;
  watermarked_path_expr text;
  watermark_profile_expr text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'watermarked_path'
  ) INTO has_watermarked_path;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'watermark_profile_id'
  ) INTO has_watermark_profile_id;

  watermarked_path_expr := CASE
    WHEN has_watermarked_path THEN 'p.watermarked_path AS watermarked_path'
    ELSE 'NULL::text AS watermarked_path'
  END;

  watermark_profile_expr := CASE
    WHEN has_watermark_profile_id THEN 'p.watermark_profile_id AS watermark_profile_id'
    ELSE 'NULL::uuid AS watermark_profile_id'
  END;

  EXECUTE format($view$
    CREATE OR REPLACE VIEW public.public_catalog_products
    WITH (security_invoker = true)
    AS
    SELECT
      p.id,
      p.producer_id,
      p.title,
      p.slug,
      p.description,
      p.product_type,
      p.genre_id,
      g.name AS genre_name,
      g.name_en AS genre_name_en,
      g.name_de AS genre_name_de,
      g.slug AS genre_slug,
      p.mood_id,
      m.name AS mood_name,
      m.name_en AS mood_name_en,
      m.name_de AS mood_name_de,
      m.slug AS mood_slug,
      p.bpm,
      p.key_signature,
      p.price,
      %s,
      p.watermarked_bucket,
      p.preview_url,
      p.exclusive_preview_url,
      p.cover_image_url,
      p.is_exclusive,
      p.is_sold,
      p.sold_at,
      p.sold_to_user_id,
      p.is_published,
      p.status,
      p.version,
      p.original_beat_id,
      p.version_number,
      p.parent_product_id,
      p.archived_at,
      p.play_count,
      p.tags,
      p.duration_seconds,
      p.file_format,
      p.license_terms,
      %s,
      p.created_at,
      p.updated_at,
      p.deleted_at,
      pp.username AS producer_username,
      pp.raw_username AS producer_raw_username,
      pp.avatar_url AS producer_avatar_url,
      COALESCE(pp.is_producer_active, false) AS producer_is_active,
      COALESCE(pbr.sales_count, 0) AS sales_count,
      COALESCE(pbr.battle_wins, 0) AS battle_wins,
      COALESCE(pbr.recency_bonus, 0) AS recency_bonus,
      COALESCE(pbr.performance_score, 0) AS performance_score,
      pbr.producer_rank,
      COALESCE(pbr.top_10_flag, false) AS top_10_flag
    FROM public.products p
    LEFT JOIN public.public_producer_profiles pp
      ON pp.user_id = p.producer_id
    LEFT JOIN public.genres g
      ON g.id = p.genre_id
    LEFT JOIN public.moods m
      ON m.id = p.mood_id
    LEFT JOIN public.producer_beats_ranked pbr
      ON pbr.id = p.id
    WHERE p.deleted_at IS NULL
  $view$, watermarked_path_expr, watermark_profile_expr);
END
$$;

COMMENT ON VIEW public.public_catalog_products
IS 'Public-safe catalog read model enriched with producer top-beat priority signals.';

REVOKE ALL ON TABLE public.public_catalog_products FROM PUBLIC;
REVOKE ALL ON TABLE public.public_catalog_products FROM anon;
REVOKE ALL ON TABLE public.public_catalog_products FROM authenticated;
GRANT SELECT ON TABLE public.public_catalog_products TO anon;
GRANT SELECT ON TABLE public.public_catalog_products TO authenticated;
GRANT SELECT ON TABLE public.public_catalog_products TO service_role;

COMMIT;
