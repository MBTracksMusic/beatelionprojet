/*
  # Lock producer elite transition after sales or public history

  Problem:
  - Migration 256 allowed elite producers to manage `is_elite`, but the UPDATE
    policy compared against `public.products` inside the `products` RLS policy,
    which triggers PostgreSQL error 42P17 "infinite recursion detected in policy
    for relation products".
  - Producers must not be able to move a beat into the private Elite Hub once
    the title has already been sold or already had public marketplace exposure.
  - Admin must keep a force path through the existing admin RPC.

  Goal:
  - Remove the self-recursive `products` policy check.
  - Allow producers to set `is_elite = true` only for fresh/private beats with
    no completed sales and no public marketplace history.
  - Keep admin override behavior unchanged.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.current_product_is_elite(p_product_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(p.is_elite, false)
  FROM public.products p
  WHERE p.id = p_product_id;
$$;

CREATE OR REPLACE FUNCTION public.product_lineage_has_completed_sales(p_product_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_root_id uuid;
BEGIN
  SELECT COALESCE(p.parent_product_id, p.id)
  INTO v_root_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_root_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.purchases pu
    JOIN public.products p
      ON p.id = pu.product_id
    WHERE COALESCE(p.parent_product_id, p.id) = v_root_id
      AND pu.status IN ('completed', 'refunded')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.product_lineage_has_public_marketplace_history(p_product_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_root_id uuid;
BEGIN
  SELECT COALESCE(p.parent_product_id, p.id)
  INTO v_root_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_root_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.products p
    WHERE COALESCE(p.parent_product_id, p.id) = v_root_id
      AND COALESCE(p.is_elite, false) = false
      AND (
        COALESCE(p.is_published, false) = true
        OR p.archived_at IS NOT NULL
      )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.current_product_is_elite(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.current_product_is_elite(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.current_product_is_elite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_product_is_elite(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.product_lineage_has_completed_sales(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.product_lineage_has_completed_sales(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.product_lineage_has_completed_sales(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.product_lineage_has_completed_sales(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.product_lineage_has_public_marketplace_history(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.product_lineage_has_public_marketplace_history(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.product_lineage_has_public_marketplace_history(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.product_lineage_has_public_marketplace_history(uuid) TO service_role;

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
      COALESCE(is_elite, false) IS NOT DISTINCT FROM public.current_product_is_elite(id)
      OR (
        EXISTS (
          SELECT 1
          FROM public.user_profiles up
          WHERE up.id = auth.uid()
            AND up.account_type = 'elite_producer'
            AND up.is_producer_active = true
            AND COALESCE(up.is_deleted, false) = false
            AND up.deleted_at IS NULL
        )
        AND public.current_product_is_elite(id) = true
      )
      OR (
        EXISTS (
          SELECT 1
          FROM public.user_profiles up
          WHERE up.id = auth.uid()
            AND up.account_type = 'elite_producer'
            AND up.is_producer_active = true
            AND COALESCE(up.is_deleted, false) = false
            AND up.deleted_at IS NULL
        )
        AND public.current_product_is_elite(id) = false
        AND COALESCE(is_elite, false) = true
        AND public.product_lineage_has_completed_sales(id) = false
        AND public.product_lineage_has_public_marketplace_history(id) = false
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

  IF v_requested_is_elite = true AND v_actor_is_elite_producer = false THEN
    RAISE EXCEPTION 'elite_producer_required'
      USING ERRCODE = '42501';
  END IF;

  IF v_requested_is_elite = true
     AND v_source.is_elite = false
     AND (
       public.product_lineage_has_completed_sales(v_source.id)
       OR public.product_lineage_has_public_marketplace_history(v_source.id)
     ) THEN
    RAISE EXCEPTION 'elite_status_locked_by_sales_or_public_history'
      USING ERRCODE = '23514';
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
