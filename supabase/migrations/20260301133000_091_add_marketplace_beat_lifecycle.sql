/*
  # Beat marketplace lifecycle rules

  - Adds lifecycle status/versioning fields to products.
  - Adds immutable purchase snapshots for sold beats.
  - Secures beat deletion/removal/versioning through RPCs.
  - Prevents direct client deletes and public visibility for removed beats.
*/

BEGIN;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS original_beat_id uuid;

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_status_check;

ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_version_positive_check;

ALTER TABLE public.products
  ADD CONSTRAINT products_status_check
    CHECK (status IN ('active', 'removed_from_sale', 'archived')),
  ADD CONSTRAINT products_version_positive_check
    CHECK (version >= 1);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'products_original_beat_id_fkey'
      AND conrelid = 'public.products'::regclass
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_original_beat_id_fkey
      FOREIGN KEY (original_beat_id)
      REFERENCES public.products(id)
      ON DELETE SET NULL;
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_products_status_not_deleted
  ON public.products (status, updated_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_products_original_beat_id
  ON public.products (original_beat_id)
  WHERE original_beat_id IS NOT NULL;

UPDATE public.products
SET
  status = CASE
    WHEN deleted_at IS NOT NULL THEN 'archived'
    ELSE COALESCE(NULLIF(btrim(status), ''), 'active')
  END,
  version = GREATEST(COALESCE(version, 1), 1)
WHERE deleted_at IS NOT NULL
   OR status IS NULL
   OR btrim(status) = ''
   OR version IS NULL
   OR version < 1;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS beat_title_snapshot text,
  ADD COLUMN IF NOT EXISTS beat_slug_snapshot text,
  ADD COLUMN IF NOT EXISTS audio_path_snapshot text,
  ADD COLUMN IF NOT EXISTS cover_image_url_snapshot text,
  ADD COLUMN IF NOT EXISTS beat_version_snapshot integer,
  ADD COLUMN IF NOT EXISTS price_snapshot integer,
  ADD COLUMN IF NOT EXISTS currency_snapshot text,
  ADD COLUMN IF NOT EXISTS producer_display_name_snapshot text,
  ADD COLUMN IF NOT EXISTS license_type_snapshot text,
  ADD COLUMN IF NOT EXISTS license_name_snapshot text;

CREATE INDEX IF NOT EXISTS idx_purchases_product_status
  ON public.purchases (product_id, status);

CREATE OR REPLACE FUNCTION public.populate_purchase_snapshots()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product public.products%ROWTYPE;
  v_producer_display_name text;
  v_license_name text;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = NEW.product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  SELECT COALESCE(NULLIF(up.full_name, ''), NULLIF(up.username, ''), up.email, '')
  INTO v_producer_display_name
  FROM public.user_profiles up
  WHERE up.id = NEW.producer_id;

  IF NEW.license_id IS NOT NULL THEN
    SELECT l.name
    INTO v_license_name
    FROM public.licenses l
    WHERE l.id = NEW.license_id;
  END IF;

  NEW.beat_title_snapshot := COALESCE(NULLIF(btrim(NEW.beat_title_snapshot), ''), v_product.title);
  NEW.beat_slug_snapshot := COALESCE(NULLIF(btrim(NEW.beat_slug_snapshot), ''), v_product.slug);
  NEW.audio_path_snapshot := COALESCE(
    NULLIF(btrim(NEW.audio_path_snapshot), ''),
    NULLIF(btrim(COALESCE(v_product.master_path, '')), ''),
    NULLIF(btrim(COALESCE(v_product.master_url, '')), ''),
    NULLIF(btrim(COALESCE(v_product.watermarked_path, '')), ''),
    NULLIF(btrim(COALESCE(v_product.preview_url, '')), '')
  );
  NEW.cover_image_url_snapshot := COALESCE(
    NULLIF(btrim(NEW.cover_image_url_snapshot), ''),
    NULLIF(btrim(COALESCE(v_product.cover_image_url, '')), '')
  );
  NEW.beat_version_snapshot := COALESCE(NEW.beat_version_snapshot, v_product.version, 1);
  NEW.price_snapshot := COALESCE(NEW.price_snapshot, NEW.amount, v_product.price);
  NEW.currency_snapshot := COALESCE(NULLIF(btrim(NEW.currency_snapshot), ''), NEW.currency);
  NEW.producer_display_name_snapshot := COALESCE(
    NULLIF(btrim(NEW.producer_display_name_snapshot), ''),
    NULLIF(btrim(COALESCE(v_producer_display_name, '')), '')
  );
  NEW.license_type_snapshot := COALESCE(
    NULLIF(btrim(NEW.license_type_snapshot), ''),
    NULLIF(btrim(COALESCE(NEW.license_type, '')), '')
  );
  NEW.license_name_snapshot := COALESCE(
    NULLIF(btrim(NEW.license_name_snapshot), ''),
    NULLIF(btrim(COALESCE(v_license_name, '')), ''),
    NULLIF(btrim(COALESCE(NEW.license_type, '')), '')
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS populate_purchase_snapshots_trigger ON public.purchases;

CREATE TRIGGER populate_purchase_snapshots_trigger
  BEFORE INSERT ON public.purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.populate_purchase_snapshots();

DO $$
DECLARE
  has_master_path boolean;
  has_watermarked_path boolean;
  sql_text text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'master_path'
  ) INTO has_master_path;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'watermarked_path'
  ) INTO has_watermarked_path;

  sql_text := $sql$
UPDATE public.purchases pu
SET
  beat_title_snapshot = COALESCE(NULLIF(btrim(pu.beat_title_snapshot), ''), p.title),
  beat_slug_snapshot = COALESCE(NULLIF(btrim(pu.beat_slug_snapshot), ''), p.slug),
  audio_path_snapshot = COALESCE(
    NULLIF(btrim(pu.audio_path_snapshot), '')
$sql$;

  IF has_master_path THEN
    sql_text := sql_text || $sql$,
    NULLIF(btrim(COALESCE(p.master_path, '')), '')
$sql$;
  END IF;

  sql_text := sql_text || $sql$,
    NULLIF(btrim(COALESCE(p.master_url, '')), '')
$sql$;

  IF has_watermarked_path THEN
    sql_text := sql_text || $sql$,
    NULLIF(btrim(COALESCE(p.watermarked_path, '')), '')
$sql$;
  END IF;

  sql_text := sql_text || $sql$,
    NULLIF(btrim(COALESCE(p.preview_url, '')), '')
  ),
  cover_image_url_snapshot = COALESCE(
    NULLIF(btrim(pu.cover_image_url_snapshot), ''),
    NULLIF(btrim(COALESCE(p.cover_image_url, '')), '')
  ),
  beat_version_snapshot = COALESCE(pu.beat_version_snapshot, p.version, 1),
  price_snapshot = COALESCE(pu.price_snapshot, pu.amount, p.price),
  currency_snapshot = COALESCE(NULLIF(btrim(pu.currency_snapshot), ''), pu.currency),
  producer_display_name_snapshot = COALESCE(
    NULLIF(btrim(pu.producer_display_name_snapshot), ''),
    NULLIF(btrim(COALESCE(up.full_name, '')), ''),
    NULLIF(btrim(COALESCE(up.username, '')), ''),
    up.email
  ),
  license_type_snapshot = COALESCE(
    NULLIF(btrim(pu.license_type_snapshot), ''),
    NULLIF(btrim(COALESCE(pu.license_type, '')), '')
  ),
  license_name_snapshot = COALESCE(
    NULLIF(btrim(pu.license_name_snapshot), ''),
    NULLIF(
      btrim(
        COALESCE(
          (
            SELECT l.name
            FROM public.licenses l
            WHERE l.id = pu.license_id
          ),
          ''
        )
      ),
      ''
    ),
    NULLIF(btrim(COALESCE(pu.license_type, '')), '')
  )
FROM public.products p
LEFT JOIN public.user_profiles up ON up.id = p.producer_id
WHERE p.id = pu.product_id
$sql$;

  EXECUTE sql_text;
END
$$;

DROP POLICY IF EXISTS "Anyone can view published products" ON public.products;
CREATE POLICY "Anyone can view published products"
  ON public.products
  FOR SELECT
  USING (
    deleted_at IS NULL
    AND status = 'active'
    AND is_published = true
    AND (is_exclusive = false OR (is_exclusive = true AND is_sold = false))
  );

DROP POLICY IF EXISTS "Producers can view own products" ON public.products;
CREATE POLICY "Producers can view own products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND producer_id = auth.uid()
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

DROP POLICY IF EXISTS "Producers can update own unsold products" ON public.products;
CREATE POLICY "Producers can update own unsold products"
  ON public.products
  FOR UPDATE
  TO authenticated
  USING (
    producer_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.status IN ('completed', 'refunded')
    )
  )
  WITH CHECK (
    producer_id = auth.uid()
  );

DROP POLICY IF EXISTS "Producers can delete own unsold products" ON public.products;

CREATE OR REPLACE FUNCTION public.delete_beat_if_no_sales(p_beat_id uuid)
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
  WHERE id = p_beat_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'beat_not_found';
  END IF;

  IF v_actor IS NULL OR v_product.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = p_beat_id
    AND pu.status IN ('completed', 'refunded');

  IF v_sales_count > 0 THEN
    RAISE EXCEPTION 'beat_has_sales';
  END IF;

  DELETE FROM public.products
  WHERE id = p_beat_id
    AND producer_id = v_actor;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'delete_failed';
  END IF;

  RETURN jsonb_build_object(
    'deleted', true,
    'product_id', v_product.id,
    'storage_cleanup', jsonb_build_object(
      'master_path', v_product.master_path,
      'master_url', v_product.master_url,
      'watermarked_path', v_product.watermarked_path,
      'preview_url', v_product.preview_url,
      'exclusive_preview_url', v_product.exclusive_preview_url,
      'cover_image_url', v_product.cover_image_url
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_beat_from_sale(p_beat_id uuid)
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
  WHERE id = p_beat_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'beat_not_found';
  END IF;

  IF v_actor IS NULL OR v_product.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  UPDATE public.products
  SET
    status = 'removed_from_sale',
    is_published = false,
    updated_at = now()
  WHERE id = p_beat_id
  RETURNING * INTO v_product;

  RETURN v_product;
END;
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
  v_actor uuid := auth.uid();
  v_source public.products%ROWTYPE;
  v_new_product public.products%ROWTYPE;
  v_next_version integer;
  v_original_beat_id uuid;
  v_generated_slug text;
BEGIN
  SELECT *
  INTO v_source
  FROM public.products
  WHERE id = p_beat_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'beat_not_found';
  END IF;

  IF v_actor IS NULL OR v_source.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  v_next_version := GREATEST(COALESCE(v_source.version, 1), 1) + 1;
  v_original_beat_id := COALESCE(v_source.original_beat_id, v_source.id);
  v_generated_slug := COALESCE(
    NULLIF(btrim(COALESCE(p_new_data->>'slug', '')), ''),
    format('%s-v%s-%s', v_source.slug, v_next_version, substr(gen_random_uuid()::text, 1, 8))
  );

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
    watermarked_path,
    preview_url,
    exclusive_preview_url,
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
    status,
    version,
    original_beat_id,
    processing_status,
    processing_error,
    processed_at,
    preview_signature,
    last_watermark_hash,
    watermarked_bucket,
    preview_version
  )
  VALUES (
    v_source.producer_id,
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'title', '')), ''), v_source.title),
    v_generated_slug,
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'description', '')), ''), v_source.description),
    'beat',
    COALESCE(NULLIF(COALESCE(p_new_data->>'genre_id', ''), '')::uuid, v_source.genre_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'mood_id', ''), '')::uuid, v_source.mood_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'bpm', ''), '')::integer, v_source.bpm),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'key_signature', '')), ''), v_source.key_signature),
    COALESCE(NULLIF(COALESCE(p_new_data->>'price', ''), '')::integer, v_source.price),
    NULLIF(btrim(COALESCE(p_new_data->>'watermarked_path', '')), ''),
    NULLIF(btrim(COALESCE(p_new_data->>'preview_url', '')), ''),
    NULLIF(btrim(COALESCE(p_new_data->>'exclusive_preview_url', '')), ''),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'cover_image_url', '')), ''), v_source.cover_image_url),
    COALESCE(NULLIF(COALESCE(p_new_data->>'is_exclusive', ''), '')::boolean, v_source.is_exclusive),
    false,
    NULL,
    NULL,
    COALESCE(NULLIF(COALESCE(p_new_data->>'is_published', ''), '')::boolean, false),
    0,
    CASE
      WHEN jsonb_typeof(p_new_data->'tags') = 'array' THEN ARRAY(
        SELECT jsonb_array_elements_text(COALESCE(p_new_data->'tags', '[]'::jsonb))
      )
      ELSE v_source.tags
    END,
    COALESCE(NULLIF(COALESCE(p_new_data->>'duration_seconds', ''), '')::integer, v_source.duration_seconds),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'file_format', '')), ''), v_source.file_format),
    COALESCE(p_new_data->'license_terms', v_source.license_terms),
    v_source.watermark_profile_id,
    NULL,
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'master_path', '')), ''), v_source.master_path),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'master_url', '')), ''), v_source.master_url),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'status', '')), ''), 'active'),
    v_next_version,
    v_original_beat_id,
    'pending',
    NULL,
    NULL,
    NULL,
    NULL,
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'watermarked_bucket', '')), ''), v_source.watermarked_bucket),
    1
  )
  RETURNING * INTO v_new_product;

  RETURN v_new_product;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.populate_purchase_snapshots() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_beat_if_no_sales(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.remove_beat_from_sale(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_new_version_from_beat(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.delete_beat_if_no_sales(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_beat_if_no_sales(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.remove_beat_from_sale(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_beat_from_sale(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_new_version_from_beat(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_new_version_from_beat(uuid, jsonb) TO service_role;

COMMIT;
