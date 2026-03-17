/*
  # Public catalog read model (beats marketplace)

  Goals:
  - Provide a single, public-safe read model for catalog/discovery pages.
  - Remove repeated frontend joins/mapping over products + producer profile + genre + mood.
  - Keep writes/purchases/cart flows unchanged (read-only additive view).
*/

BEGIN;

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
      COALESCE(pp.is_producer_active, false) AS producer_is_active
    FROM public.products p
    LEFT JOIN public.public_producer_profiles pp
      ON pp.user_id = p.producer_id
    LEFT JOIN public.genres g
      ON g.id = p.genre_id
    LEFT JOIN public.moods m
      ON m.id = p.mood_id
    WHERE p.deleted_at IS NULL
  $view$, watermarked_path_expr, watermark_profile_expr);
END
$$;

COMMENT ON VIEW public.public_catalog_products
IS 'Public-safe catalog read model for beats/exclusives/kits discovery screens.';

REVOKE ALL ON TABLE public.public_catalog_products FROM PUBLIC;
REVOKE ALL ON TABLE public.public_catalog_products FROM anon;
REVOKE ALL ON TABLE public.public_catalog_products FROM authenticated;

GRANT SELECT ON TABLE public.public_catalog_products TO anon;
GRANT SELECT ON TABLE public.public_catalog_products TO authenticated;
GRANT SELECT ON TABLE public.public_catalog_products TO service_role;

COMMIT;
