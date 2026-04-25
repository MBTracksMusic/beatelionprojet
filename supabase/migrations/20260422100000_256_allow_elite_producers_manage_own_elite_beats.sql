/*
  # Allow elite producers to manage their own elite beats

  Problem:
  - `products.is_elite` was introduced as an admin-only flag.
  - Elite producers cannot create or update their own private/exclusive beats
    from `/producer/upload`.
  - Version publishing ignores `is_elite` entirely.

  Goal:
  - Allow active elite producers to create new own beats with `is_elite = true`.
  - Allow active elite producers to toggle `is_elite` on their own unsold beats.
  - Keep non-elite producers unable to change the flag.
  - Preserve existing elite visibility on version publishing unless an elite
    producer explicitly changes it.
*/

BEGIN;

DROP POLICY IF EXISTS "Active producers can create products" ON public.products;
CREATE POLICY "Active producers can create products"
  ON public.products
  FOR INSERT
  TO authenticated
  WITH CHECK (
    producer_id = auth.uid()
    AND public.is_current_user_active(auth.uid()) = true
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
        AND COALESCE(up.is_deleted, false) = false
        AND up.deleted_at IS NULL
    )
    AND (
      COALESCE(is_elite, false) = false
      OR EXISTS (
        SELECT 1
        FROM public.user_profiles up
        WHERE up.id = auth.uid()
          AND up.account_type = 'elite_producer'
          AND up.is_producer_active = true
          AND COALESCE(up.is_deleted, false) = false
          AND up.deleted_at IS NULL
      )
    )
    AND (
      NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
      OR public.can_publish_beat(auth.uid(), NULL)
    )
  );

DROP POLICY IF EXISTS "Producers can update own unsold products" ON public.products;
CREATE POLICY "Producers can update own unsold products"
  ON public.products
  FOR UPDATE
  TO authenticated
  USING (
    producer_id = auth.uid()
    AND deleted_at IS NULL
    AND public.is_current_user_active(auth.uid()) = true
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
        AND COALESCE(up.is_deleted, false) = false
        AND up.deleted_at IS NULL
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.status IN ('completed', 'refunded')
    )
  )
  WITH CHECK (
    producer_id = auth.uid()
    AND deleted_at IS NULL
    AND public.is_current_user_active(auth.uid()) = true
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
        AND COALESCE(up.is_deleted, false) = false
        AND up.deleted_at IS NULL
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.status IN ('completed', 'refunded')
    )
    AND (
      is_elite IS NOT DISTINCT FROM (
        SELECT current_product.is_elite
        FROM public.products AS current_product
        WHERE current_product.id = products.id
      )
      OR EXISTS (
        SELECT 1
        FROM public.user_profiles up
        WHERE up.id = auth.uid()
          AND up.account_type = 'elite_producer'
          AND up.is_producer_active = true
          AND COALESCE(up.is_deleted, false) = false
          AND up.deleted_at IS NULL
      )
    )
    AND (
      NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
      OR public.can_publish_beat(auth.uid(), id)
    )
  );

CREATE OR REPLACE FUNCTION public.rpc_publish_product_version(
  p_source_product_id uuid,
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
  v_root_id uuid;
  v_next_version integer;
  v_new_product public.products%ROWTYPE;
  v_actor_is_elite_producer boolean := false;
  v_requested_is_elite boolean;
BEGIN
  SELECT *
  INTO v_source
  FROM public.products
  WHERE id = p_source_product_id
    AND product_type = 'beat'
    AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  IF v_actor IS NULL OR v_source.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    WHERE up.id = v_actor
      AND up.account_type = 'elite_producer'
      AND up.is_producer_active = true
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  )
  INTO v_actor_is_elite_producer;

  v_requested_is_elite := COALESCE(
    NULLIF(COALESCE(p_new_data->>'is_elite', ''), '')::boolean,
    v_source.is_elite
  );

  IF v_requested_is_elite IS DISTINCT FROM v_source.is_elite
     AND v_actor_is_elite_producer = false THEN
    RAISE EXCEPTION 'elite_producer_required'
      USING ERRCODE = '42501';
  END IF;

  v_root_id := COALESCE(v_source.parent_product_id, v_source.id);

  PERFORM 1
  FROM public.products
  WHERE parent_product_id = v_root_id
    AND product_type = 'beat'
    AND deleted_at IS NULL
  FOR UPDATE;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_version
  FROM public.products
  WHERE parent_product_id = v_root_id
    AND product_type = 'beat'
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
    is_elite,
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
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'title', '')), ''), v_source.title),
    NULLIF(btrim(COALESCE(p_new_data->>'slug', '')), ''),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'description', '')), ''), v_source.description),
    'beat',
    COALESCE(NULLIF(COALESCE(p_new_data->>'genre_id', ''), '')::uuid, v_source.genre_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'mood_id', ''), '')::uuid, v_source.mood_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'bpm', ''), '')::integer, v_source.bpm),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'key_signature', '')), ''), v_source.key_signature),
    COALESCE(NULLIF(COALESCE(p_new_data->>'price', ''), '')::integer, v_source.price),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'cover_image_url', '')), ''), v_source.cover_image_url),
    COALESCE(NULLIF(COALESCE(p_new_data->>'is_exclusive', ''), '')::boolean, v_source.is_exclusive),
    v_requested_is_elite,
    false,
    NULL,
    NULL,
    true,
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
    NULL,
    NULL,
    NULL,
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'watermarked_bucket', '')), ''), v_source.watermarked_bucket),
    'pending',
    NULL,
    NULL,
    NULL,
    NULL,
    1,
    'archived',
    v_next_version,
    v_next_version,
    v_root_id,
    v_root_id,
    now()
  )
  RETURNING * INTO v_new_product;

  UPDATE public.products
  SET
    status = 'archived',
    archived_at = COALESCE(archived_at, now()),
    is_published = false,
    updated_at = now()
  WHERE parent_product_id = v_root_id
    AND status = 'active'
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  UPDATE public.products
  SET
    status = 'active',
    archived_at = NULL,
    is_published = true,
    updated_at = now()
  WHERE id = v_new_product.id
  RETURNING * INTO v_new_product;

  RETURN v_new_product;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) TO service_role;

COMMIT;
