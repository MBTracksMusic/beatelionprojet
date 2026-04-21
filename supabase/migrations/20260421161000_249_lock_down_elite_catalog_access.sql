/*
  # Lock down Elite Hub data access

  Problem:
  - `products` remains publicly readable for active published beats.
  - `EliteHub` queried `products` directly with `is_elite = true`.
  - Result: elite beats metadata could be enumerated outside the intended
    elite producer / verified label audience.

  Fix:
  - Create a dedicated private view with only safe catalog columns.
  - Gate rows server-side with auth.uid() + account_type / is_verified.
  - Grant access only to authenticated users.
*/

BEGIN;

CREATE OR REPLACE VIEW public.elite_catalog_products AS
SELECT
  p.id,
  p.producer_id,
  p.title,
  p.slug,
  p.description,
  p.product_type,
  p.genre_id,
  p.mood_id,
  p.bpm,
  p.key_signature,
  p.price,
  p.early_access_until,
  p.watermarked_path,
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
  p.watermark_profile_id,
  p.created_at,
  p.updated_at,
  p.deleted_at,
  p.is_elite
FROM public.products p
WHERE p.product_type = 'beat'
  AND p.is_published = true
  AND p.status = 'active'
  AND p.deleted_at IS NULL
  AND p.is_elite = true
  AND EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = auth.uid()
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
      AND (
        up.role = 'admin'
        OR up.account_type = 'elite_producer'
        OR (up.account_type = 'label' AND up.is_verified = true)
      )
  );

ALTER VIEW public.elite_catalog_products SET (security_invoker = false);

COMMENT ON VIEW public.elite_catalog_products IS
  'Private elite-only beat catalog. Safe catalog fields only. Server-side gated.';

REVOKE ALL ON TABLE public.elite_catalog_products FROM PUBLIC;
REVOKE ALL ON TABLE public.elite_catalog_products FROM anon;
REVOKE ALL ON TABLE public.elite_catalog_products FROM authenticated;
GRANT SELECT ON TABLE public.elite_catalog_products TO authenticated;
GRANT SELECT ON TABLE public.elite_catalog_products TO service_role;

COMMIT;
