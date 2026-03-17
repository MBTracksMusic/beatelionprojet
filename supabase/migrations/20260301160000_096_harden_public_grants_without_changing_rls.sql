/*
  # Harden PUBLIC grants without changing RLS logic

  Goal:
  - Remove unnecessary table/view/column grants from PUBLIC.
  - Keep intended client reads working through explicit anon/authenticated grants.
  - Do not modify existing RLS policies or business logic.

  Public-read-by-design tables kept readable for anon/authenticated:
  - public.app_settings: only non-sensitive frontend configuration must live here.
  - public.producer_plan_config: public pricing catalog for the pricing page.
  - public.licenses: public license catalog for checkout and product pages.
  - public.battle_votes: existing RLS intentionally keeps votes readable; this migration only clarifies grants.
  - public.public_products: safe read projection/view for products.

  Notes:
  - This migration intentionally does NOT broaden access to admin/private tables.
  - This migration intentionally does NOT change USING (true) policies already relied on by the app.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) products: remove PUBLIC grants while preserving explicit client-role reads
-- ---------------------------------------------------------------------------
REVOKE SELECT ON TABLE public.products FROM PUBLIC;

DO $$
DECLARE
  public_granted_columns text;
BEGIN
  SELECT string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO public_granted_columns
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'products'
    AND c.column_name = ANY (ARRAY[
      'id',
      'producer_id',
      'title',
      'slug',
      'description',
      'product_type',
      'genre_id',
      'mood_id',
      'bpm',
      'key_signature',
      'price',
      'watermarked_path',
      'watermarked_bucket',
      'preview_url',
      'exclusive_preview_url',
      'cover_image_url',
      'is_exclusive',
      'is_sold',
      'sold_at',
      'sold_to_user_id',
      'is_published',
      'play_count',
      'tags',
      'duration_seconds',
      'file_format',
      'license_terms',
      'watermark_profile_id',
      'created_at',
      'updated_at',
      'deleted_at',
      'status',
      'version',
      'original_beat_id',
      'version_number',
      'parent_product_id',
      'archived_at'
    ]);

  IF public_granted_columns IS NOT NULL THEN
    EXECUTE format('REVOKE SELECT (%s) ON TABLE public.products FROM PUBLIC', public_granted_columns);
    EXECUTE format('GRANT SELECT (%s) ON TABLE public.products TO anon', public_granted_columns);
    EXECUTE format('GRANT SELECT (%s) ON TABLE public.products TO authenticated', public_granted_columns);
  END IF;
END
$$;

-- Legacy rollback migration granted these sensitive columns to PUBLIC.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'master_path'
  ) THEN
    EXECUTE 'REVOKE SELECT(master_path) ON TABLE public.products FROM PUBLIC';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'master_url'
  ) THEN
    EXECUTE 'REVOKE SELECT(master_url) ON TABLE public.products FROM PUBLIC';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2) public_products: safe projection stays readable to client roles, not PUBLIC
-- ---------------------------------------------------------------------------
REVOKE SELECT ON TABLE public.public_products FROM PUBLIC;
GRANT SELECT ON TABLE public.public_products TO anon;
GRANT SELECT ON TABLE public.public_products TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Public-read-by-design tables: explicit anon/authenticated grants only
-- ---------------------------------------------------------------------------
REVOKE SELECT ON TABLE public.app_settings FROM PUBLIC;
GRANT SELECT ON TABLE public.app_settings TO anon;
GRANT SELECT ON TABLE public.app_settings TO authenticated;

REVOKE SELECT ON TABLE public.producer_plan_config FROM PUBLIC;
GRANT SELECT ON TABLE public.producer_plan_config TO anon;
GRANT SELECT ON TABLE public.producer_plan_config TO authenticated;

REVOKE SELECT ON TABLE public.licenses FROM PUBLIC;
GRANT SELECT ON TABLE public.licenses TO anon;
GRANT SELECT ON TABLE public.licenses TO authenticated;

REVOKE SELECT ON TABLE public.battle_votes FROM PUBLIC;
GRANT SELECT ON TABLE public.battle_votes TO anon;
GRANT SELECT ON TABLE public.battle_votes TO authenticated;

COMMIT;
