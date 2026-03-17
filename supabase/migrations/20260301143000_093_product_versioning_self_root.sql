/*
  # Product versioning with self-root lineage

  - Adds self-root lineage columns for beat versions.
  - Guarantees a single active version per root beat.
  - Restricts public visibility to active published beats.
  - Lets producers see all their versions and buyers see purchased versions.
  - Adds secure RPCs for version creation, archival, and hard delete without sales.
*/

BEGIN;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS version_number integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS parent_product_id uuid,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_status_check;

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_version_number_positive_check;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_parent_product_id_fkey'
      AND conrelid = 'public.products'::regclass
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_parent_product_id_fkey
      FOREIGN KEY (parent_product_id)
      REFERENCES public.products(id)
      ON DELETE SET NULL;
  END IF;
END
$$;

UPDATE public.products
SET
  status = CASE
    WHEN deleted_at IS NOT NULL THEN 'archived'
    WHEN status = 'removed_from_sale' THEN 'archived'
    WHEN status NOT IN ('active', 'archived') THEN 'archived'
    WHEN status IS NULL OR btrim(status) = '' THEN 'active'
    ELSE status
  END,
  version_number = GREATEST(COALESCE(version_number, version, 1), 1),
  version = GREATEST(COALESCE(version_number, version, 1), 1),
  parent_product_id = COALESCE(parent_product_id, original_beat_id, id),
  original_beat_id = COALESCE(parent_product_id, original_beat_id, id),
  archived_at = CASE
    WHEN deleted_at IS NOT NULL OR status = 'removed_from_sale' OR status = 'archived'
      THEN COALESCE(archived_at, deleted_at, updated_at, now())
    ELSE archived_at
  END
WHERE parent_product_id IS NULL
   OR original_beat_id IS NULL
   OR version_number IS NULL
   OR version_number < 1
   OR status IS NULL
   OR btrim(status) = ''
   OR status = 'removed_from_sale'
   OR status NOT IN ('active', 'archived')
   OR deleted_at IS NOT NULL;

ALTER TABLE public.products
  ADD CONSTRAINT products_status_check
    CHECK (status IN ('active', 'archived')),
  ADD CONSTRAINT products_version_number_positive_check
    CHECK (version_number >= 1);

WITH duplicate_active_versions AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY parent_product_id
      ORDER BY updated_at DESC, created_at DESC, id DESC
    ) AS row_rank
  FROM public.products
  WHERE product_type = 'beat'
    AND deleted_at IS NULL
    AND status = 'active'
)
UPDATE public.products p
SET
  status = 'archived',
  archived_at = COALESCE(p.archived_at, now()),
  is_published = false,
  updated_at = now()
FROM duplicate_active_versions dav
WHERE p.id = dav.id
  AND dav.row_rank > 1;

CREATE INDEX IF NOT EXISTS idx_products_parent_product_version_desc
  ON public.products (parent_product_id, version_number DESC);

CREATE INDEX IF NOT EXISTS idx_products_producer_status
  ON public.products (producer_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_single_active_version_per_root
  ON public.products (parent_product_id)
  WHERE product_type = 'beat'
    AND deleted_at IS NULL
    AND status = 'active';

CREATE OR REPLACE FUNCTION public.normalize_product_version_lineage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS NULL THEN
    NEW.id := gen_random_uuid();
  END IF;

  NEW.version_number := GREATEST(COALESCE(NEW.version_number, NEW.version, 1), 1);
  NEW.version := NEW.version_number;

  IF NEW.parent_product_id IS NULL THEN
    NEW.parent_product_id := COALESCE(NEW.original_beat_id, NEW.id);
  END IF;

  NEW.original_beat_id := NEW.parent_product_id;

  IF NEW.status IS NULL OR btrim(NEW.status) = '' THEN
    NEW.status := 'active';
  END IF;

  IF NEW.status = 'archived' THEN
    NEW.archived_at := COALESCE(NEW.archived_at, now());
    NEW.is_published := false;
  ELSE
    NEW.archived_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS normalize_product_version_lineage_trigger ON public.products;

CREATE TRIGGER normalize_product_version_lineage_trigger
  BEFORE INSERT OR UPDATE OF version_number, version, parent_product_id, original_beat_id, status, archived_at, is_published
  ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_product_version_lineage();

REVOKE SELECT ON TABLE public.products FROM PUBLIC;
REVOKE SELECT ON TABLE public.products FROM anon;
REVOKE SELECT ON TABLE public.products FROM authenticated;

DO $$
DECLARE
  safe_columns text;
BEGIN
  SELECT string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position)
  INTO safe_columns
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

  IF safe_columns IS NULL THEN
    RAISE EXCEPTION 'No grantable columns found for public.products';
  END IF;

  EXECUTE format('GRANT SELECT (%s) ON TABLE public.products TO anon', safe_columns);
  EXECUTE format('GRANT SELECT (%s) ON TABLE public.products TO authenticated', safe_columns);
END
$$;

DROP POLICY IF EXISTS "Anyone can view published products" ON public.products;
DROP POLICY IF EXISTS "Public can view active products" ON public.products;
CREATE POLICY "Public can view active products"
  ON public.products
  FOR SELECT
  TO anon, authenticated
  USING (
    deleted_at IS NULL
    AND status = 'active'
    AND (
      is_published IS DISTINCT FROM false
    )
    AND (is_exclusive = false OR (is_exclusive = true AND is_sold = false))
  );

DROP POLICY IF EXISTS "Producers can view own products" ON public.products;
DROP POLICY IF EXISTS "Producer can view own products" ON public.products;
CREATE POLICY "Producer can view own products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() = producer_id
    AND deleted_at IS NULL
  );

DROP POLICY IF EXISTS "Buyers can view purchased products" ON public.products;
CREATE POLICY "Buyers can view purchased products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.user_id = auth.uid()
        AND pu.status IN ('completed', 'refunded')
    )
  );

DROP POLICY IF EXISTS "Producers can delete own unsold products" ON public.products;
DROP POLICY IF EXISTS "Producer can delete own products" ON public.products;

CREATE OR REPLACE FUNCTION public.rpc_create_product_version(p_product_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_source public.products%ROWTYPE;
  v_root_id uuid;
  v_next_version integer;
  v_new_product_id uuid;
BEGIN
  SELECT *
  INTO v_source
  FROM public.products
  WHERE id = p_product_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  IF v_actor IS NULL OR v_source.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  v_root_id := COALESCE(v_source.parent_product_id, v_source.id);

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_version
  FROM public.products
  WHERE parent_product_id = v_root_id
    AND deleted_at IS NULL;

  UPDATE public.products
  SET
    status = 'archived',
    archived_at = COALESCE(archived_at, now()),
    is_published = false,
    updated_at = now()
  WHERE parent_product_id = v_root_id
    AND status = 'active'
    AND deleted_at IS NULL;

  INSERT INTO public.products (
    producer_id,
    title,
    slug,
    description,
    product_type,
    genre_id,
    mood_id,
    bpm,
    key_signature,
    price,
    cover_image_url,
    is_exclusive,
    is_sold,
    sold_at,
    sold_to_user_id,
    is_published,
    play_count,
    tags,
    duration_seconds,
    file_format,
    license_terms,
    watermark_profile_id,
    deleted_at,
    master_path,
    master_url,
    watermarked_path,
    preview_url,
    exclusive_preview_url,
    watermarked_bucket,
    processing_status,
    processing_error,
    processed_at,
    preview_signature,
    last_watermark_hash,
    preview_version,
    status,
    version,
    version_number,
    parent_product_id,
    original_beat_id,
    archived_at
  )
  VALUES (
    v_source.producer_id,
    v_source.title,
    format('%s-v%s-%s', v_source.slug, v_next_version, substr(gen_random_uuid()::text, 1, 8)),
    v_source.description,
    v_source.product_type,
    v_source.genre_id,
    v_source.mood_id,
    v_source.bpm,
    v_source.key_signature,
    v_source.price,
    v_source.cover_image_url,
    v_source.is_exclusive,
    false,
    NULL,
    NULL,
    false,
    0,
    v_source.tags,
    v_source.duration_seconds,
    v_source.file_format,
    v_source.license_terms,
    v_source.watermark_profile_id,
    NULL,
    v_source.master_path,
    v_source.master_url,
    NULL,
    NULL,
    NULL,
    v_source.watermarked_bucket,
    'pending',
    NULL,
    NULL,
    NULL,
    NULL,
    1,
    'active',
    v_next_version,
    v_next_version,
    v_root_id,
    v_root_id,
    NULL
  )
  RETURNING id INTO v_new_product_id;

  RETURN v_new_product_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_archive_product(p_product_id uuid)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  IF v_actor IS NULL OR v_product.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  UPDATE public.products
  SET
    status = 'archived',
    archived_at = COALESCE(archived_at, now()),
    is_published = false,
    updated_at = now()
  WHERE id = p_product_id
  RETURNING * INTO v_product;

  RETURN v_product;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_delete_product_if_no_sales(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_sales_count integer := 0;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  IF v_actor IS NULL OR v_product.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = p_product_id
    AND pu.status IN ('completed', 'refunded');

  IF v_sales_count > 0 THEN
    RAISE EXCEPTION 'product_has_sales';
  END IF;

  DELETE FROM public.products
  WHERE id = p_product_id
    AND producer_id = v_actor;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'delete_failed';
  END IF;

  RETURN jsonb_build_object(
    'deleted', true,
    'product_id', v_product.id
  );
END;
$$;

-- Backward-compatible wrappers for the already integrated frontend.
CREATE OR REPLACE FUNCTION public.delete_beat_if_no_sales(p_beat_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.rpc_delete_product_if_no_sales(p_beat_id);
$$;

CREATE OR REPLACE FUNCTION public.remove_beat_from_sale(p_beat_id uuid)
RETURNS public.products
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.rpc_archive_product(p_beat_id);
$$;

CREATE OR REPLACE FUNCTION public.create_new_version_from_beat(
  p_beat_id uuid,
  p_new_data jsonb DEFAULT '{}'::jsonb
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_product_id uuid;
  v_new_product public.products%ROWTYPE;
BEGIN
  v_new_product_id := public.rpc_create_product_version(p_beat_id);

  SELECT *
  INTO v_new_product
  FROM public.products
  WHERE id = v_new_product_id;

  RETURN v_new_product;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rpc_create_product_version(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_archive_product(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.rpc_create_product_version(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_product_version(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_archive_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_archive_product(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) TO service_role;

COMMIT;
