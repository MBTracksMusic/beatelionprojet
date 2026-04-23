/*
  # Allow exclusive titles in Elite Hub and admin curation

  Why:
  - The admin "Beats prives" screen should expose exclusive titles too.
  - Admin must be able to add/remove exclusive titles from the Elite Hub.
  - The private Elite Hub view must return the same eligible audio titles that
    the admin can curate.

  Scope:
  - Extend the admin RPC to allow `product_type = 'exclusive'`.
  - Extend `elite_catalog_products` to include both `beat` and `exclusive`.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_set_product_elite_status(
  p_product_id uuid,
  p_is_elite boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT COALESCE(public.is_admin(v_actor), false) THEN
    RAISE EXCEPTION 'admin_required'
      USING ERRCODE = '42501';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required'
      USING ERRCODE = '23502';
  END IF;

  SELECT *
  INTO v_product
  FROM public.products p
  WHERE p.id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_product.product_type NOT IN ('beat', 'exclusive') THEN
    RAISE EXCEPTION 'elite_status_only_available_for_audio_products'
      USING ERRCODE = '22023';
  END IF;

  IF v_product.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'cannot_update_deleted_product'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.products
  SET is_elite = COALESCE(p_is_elite, false)
  WHERE id = p_product_id;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_product_elite_status(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_product_elite_status(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_product_elite_status(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_product_elite_status(uuid, boolean) TO service_role;

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
WHERE p.product_type IN ('beat', 'exclusive')
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
  'Private elite-only audio catalog for beats and exclusive titles. Safe catalog fields only. Server-side gated.';

REVOKE ALL ON TABLE public.elite_catalog_products FROM PUBLIC;
REVOKE ALL ON TABLE public.elite_catalog_products FROM anon;
REVOKE ALL ON TABLE public.elite_catalog_products FROM authenticated;
GRANT SELECT ON TABLE public.elite_catalog_products TO authenticated;
GRANT SELECT ON TABLE public.elite_catalog_products TO service_role;

COMMIT;
