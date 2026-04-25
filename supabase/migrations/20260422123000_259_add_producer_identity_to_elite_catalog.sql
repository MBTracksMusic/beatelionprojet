/*
  # Add producer identity fields to elite catalog view

  Problem:
  - The Elite Hub enriches producer username/avatar with a second client query to
    `public_producer_profiles`.
  - When that secondary lookup misses or is denied, Elite cards fall back to an
    empty producer profile and show "unknown producer".

  Fix:
  - Extend `elite_catalog_products` with the same safe producer identity fields
    already exposed by `public_catalog_products`.
  - Keep the Elite Hub private gating unchanged.
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
  p.is_elite,
  pp.username AS producer_username,
  pp.raw_username AS producer_raw_username,
  pp.avatar_url AS producer_avatar_url,
  COALESCE(pp.is_producer_active, false) AS producer_is_active
FROM public.products p
LEFT JOIN public.public_producer_profiles pp ON pp.user_id = p.producer_id
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
