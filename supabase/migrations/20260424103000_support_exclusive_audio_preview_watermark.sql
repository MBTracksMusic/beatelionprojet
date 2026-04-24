/*
  # Support watermark previews for exclusive audio titles

  - Exclusive titles must use product_type = 'exclusive' to satisfy the
    products.exclusive_must_have_type check constraint.
  - The preview enqueue pipeline must still process those audio products.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.prepare_product_preview_processing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.product_type NOT IN ('beat'::public.product_type, 'exclusive'::public.product_type) THEN
    RETURN NEW;
  END IF;

  NEW.watermarked_bucket := COALESCE(NULLIF(btrim(COALESCE(NEW.watermarked_bucket, '')), ''), 'beats-watermarked');
  NEW.preview_version := GREATEST(COALESCE(NEW.preview_version, 1), 1);

  IF TG_OP = 'INSERT' THEN
    NEW.processing_status := COALESCE(NULLIF(btrim(COALESCE(NEW.processing_status, '')), ''), 'pending');
    NEW.processing_error := NULL;
    IF NEW.processing_status <> 'done' THEN
      NEW.processed_at := NULL;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.master_path IS DISTINCT FROM OLD.master_path
     OR NEW.master_url IS DISTINCT FROM OLD.master_url THEN
    NEW.preview_version := GREATEST(COALESCE(OLD.preview_version, 1), 1) + 1;
    NEW.processing_status := 'pending';
    NEW.processing_error := NULL;
    NEW.processed_at := NULL;
    RETURN NEW;
  END IF;

  IF OLD.is_published = false
     AND NEW.is_published = true
     AND NEW.deleted_at IS NULL
     AND coalesce(
       nullif(btrim(COALESCE(NEW.watermarked_path, '')), ''),
       nullif(btrim(COALESCE(NEW.preview_url, '')), ''),
       nullif(btrim(COALESCE(NEW.exclusive_preview_url, '')), '')
     ) IS NULL THEN
    NEW.processing_status := 'pending';
    NEW.processing_error := NULL;
    NEW.processed_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_audio_processing_job(
  p_product_id uuid,
  p_job_type text DEFAULT 'generate_preview'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', '');
  v_product public.products%ROWTYPE;
BEGIN
  IF p_product_id IS NULL THEN
    RETURN false;
  END IF;

  IF p_job_type NOT IN ('generate_preview', 'reprocess_all') THEN
    RAISE EXCEPTION 'invalid_job_type';
  END IF;

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF p_job_type = 'reprocess_all' THEN
    IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
      RAISE EXCEPTION 'admin_required';
    END IF;
  ELSIF NOT (
    v_jwt_role = 'service_role'
    OR public.is_admin(v_actor)
    OR v_product.producer_id = v_actor
  ) THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;

  IF p_job_type = 'generate_preview' THEN
    IF v_product.product_type NOT IN ('beat'::public.product_type, 'exclusive'::public.product_type)
       OR v_product.deleted_at IS NOT NULL
       OR v_product.is_published IS DISTINCT FROM true THEN
      RETURN false;
    END IF;

    IF coalesce(
      nullif(btrim(COALESCE(v_product.master_path, '')), ''),
      nullif(btrim(COALESCE(v_product.master_url, '')), '')
    ) IS NULL THEN
      RETURN false;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.audio_processing_jobs (product_id, job_type, status)
    VALUES (p_product_id, p_job_type, 'queued');
    RETURN true;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN false;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_product_preview_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.product_type NOT IN ('beat'::public.product_type, 'exclusive'::public.product_type)
     OR NEW.deleted_at IS NOT NULL
     OR NEW.is_published IS DISTINCT FROM true THEN
    RETURN NEW;
  END IF;

  IF coalesce(
    nullif(btrim(COALESCE(NEW.master_path, '')), ''),
    nullif(btrim(COALESCE(NEW.master_url, '')), '')
  ) IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT'
     OR NEW.master_path IS DISTINCT FROM OLD.master_path
     OR NEW.master_url IS DISTINCT FROM OLD.master_url
     OR (OLD.is_published = false AND NEW.is_published = true)
     OR (OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL) THEN
    PERFORM public.enqueue_audio_processing_job(NEW.id, 'generate_preview');
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_reprocess_all_previews()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', '');
  v_enqueued_count integer := 0;
  v_skipped_count integer := 0;
  v_active_watermark_path text;
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT NULLIF(btrim(sas.watermark_audio_path), '')
  INTO v_active_watermark_path
  FROM public.site_audio_settings sas
  WHERE sas.enabled = true
  ORDER BY sas.updated_at DESC, sas.created_at DESC, sas.id DESC
  LIMIT 1;

  IF v_active_watermark_path IS NULL THEN
    RAISE EXCEPTION 'active_watermark_required';
  END IF;

  WITH candidate_products AS (
    SELECT p.id
    FROM public.products p
    WHERE p.product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
      AND p.is_published = true
      AND p.deleted_at IS NULL
      AND COALESCE(
        NULLIF(btrim(COALESCE(p.master_path, '')), ''),
        NULLIF(btrim(COALESCE(p.master_url, '')), '')
      ) IS NOT NULL
  ),
  inserted_jobs AS (
    INSERT INTO public.audio_processing_jobs (product_id, job_type, status)
    SELECT cp.id, 'generate_preview', 'queued'
    FROM candidate_products cp
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.audio_processing_jobs job
      WHERE job.product_id = cp.id
        AND job.job_type = 'generate_preview'
        AND job.status IN ('queued', 'processing')
    )
    ON CONFLICT DO NOTHING
    RETURNING product_id
  ),
  updated_products AS (
    UPDATE public.products p
    SET
      preview_version = GREATEST(COALESCE(p.preview_version, 1), 1) + 1,
      processing_status = 'pending',
      processing_error = NULL,
      processed_at = NULL
    FROM inserted_jobs ij
    WHERE p.id = ij.product_id
    RETURNING p.id
  )
  SELECT COUNT(*) INTO v_enqueued_count
  FROM updated_products;

  WITH candidate_products AS (
    SELECT p.id
    FROM public.products p
    WHERE p.product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
      AND p.is_published = true
      AND p.deleted_at IS NULL
      AND COALESCE(
        NULLIF(btrim(COALESCE(p.master_path, '')), ''),
        NULLIF(btrim(COALESCE(p.master_url, '')), '')
      ) IS NOT NULL
  )
  SELECT GREATEST(COUNT(*) - v_enqueued_count, 0)::integer
  INTO v_skipped_count
  FROM candidate_products;

  RETURN jsonb_build_object(
    'enqueued_count', v_enqueued_count,
    'skipped_count', v_skipped_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_edit_product(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_sales_count integer := 0;
  v_active_battle_count integer := 0;
  v_has_terminated_battle boolean := false;
  v_can_edit_audio boolean := false;
  v_can_edit_metadata_essentials boolean := false;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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

  SELECT COUNT(*)
  INTO v_active_battle_count
  FROM public.battles b
  WHERE b.status = 'active'
    AND (b.product1_id = p_product_id OR b.product2_id = p_product_id);

  v_has_terminated_battle := public.product_has_terminated_battle(p_product_id);
  v_can_edit_audio := v_sales_count = 0 AND v_active_battle_count = 0 AND NOT v_has_terminated_battle;
  v_can_edit_metadata_essentials := v_sales_count = 0 AND NOT v_has_terminated_battle;

  RETURN jsonb_build_object(
    'can_edit_audio', v_can_edit_audio,
    'can_edit_metadata', v_can_edit_metadata_essentials,
    'can_edit_metadata_essentials', v_can_edit_metadata_essentials,
    'must_create_new_version', v_sales_count > 0 OR v_has_terminated_battle,
    'has_sales', v_sales_count > 0,
    'has_active_battle', v_active_battle_count > 0,
    'has_terminated_battle', v_has_terminated_battle
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_product_editability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sales_count integer := 0;
  v_active_battle_count integer := 0;
  v_has_terminated_battle boolean := false;
  v_audio_changed boolean := false;
  v_metadata_essentials_changed boolean := false;
BEGIN
  IF TG_OP <> 'UPDATE'
     OR OLD.product_type NOT IN ('beat'::public.product_type, 'exclusive'::public.product_type) THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = OLD.id
    AND pu.status IN ('completed', 'refunded');

  SELECT COUNT(*)
  INTO v_active_battle_count
  FROM public.battles b
  WHERE b.status = 'active'
    AND (b.product1_id = OLD.id OR b.product2_id = OLD.id);

  v_has_terminated_battle := public.product_has_terminated_battle(OLD.id);

  v_audio_changed := NEW.master_path IS DISTINCT FROM OLD.master_path
    OR NEW.master_url IS DISTINCT FROM OLD.master_url
    OR NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds
    OR NEW.file_format IS DISTINCT FROM OLD.file_format;

  v_metadata_essentials_changed := NEW.title IS DISTINCT FROM OLD.title
    OR NEW.description IS DISTINCT FROM OLD.description
    OR NEW.product_type IS DISTINCT FROM OLD.product_type
    OR NEW.is_exclusive IS DISTINCT FROM OLD.is_exclusive
    OR NEW.price IS DISTINCT FROM OLD.price
    OR NEW.bpm IS DISTINCT FROM OLD.bpm
    OR NEW.key_signature IS DISTINCT FROM OLD.key_signature
    OR NEW.cover_image_url IS DISTINCT FROM OLD.cover_image_url
    OR NEW.genre_id IS DISTINCT FROM OLD.genre_id
    OR NEW.mood_id IS DISTINCT FROM OLD.mood_id
    OR NEW.tags IS DISTINCT FROM OLD.tags
    OR NEW.license_terms IS DISTINCT FROM OLD.license_terms;

  IF v_sales_count > 0 AND (v_audio_changed OR v_metadata_essentials_changed) THEN
    RAISE EXCEPTION 'product_must_create_new_version';
  END IF;

  IF v_has_terminated_battle AND v_audio_changed THEN
    RAISE EXCEPTION 'product_audio_locked_by_terminated_battle';
  END IF;

  IF v_has_terminated_battle AND v_metadata_essentials_changed THEN
    RAISE EXCEPTION 'product_metadata_locked_by_terminated_battle';
  END IF;

  IF v_active_battle_count > 0 AND v_audio_changed THEN
    RAISE EXCEPTION 'product_audio_locked_by_active_battle';
  END IF;

  RETURN NEW;
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
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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
  v_has_terminated_battle boolean := false;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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

  v_has_terminated_battle := public.product_has_terminated_battle(p_product_id);

  IF v_has_terminated_battle THEN
    RAISE EXCEPTION 'product_has_terminated_battle';
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
  v_new_is_exclusive boolean;
  v_new_product_type public.product_type;
BEGIN
  SELECT *
  INTO v_source
  FROM public.products
  WHERE id = p_source_product_id
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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

  IF v_requested_is_elite = true
     AND v_source.is_elite = false
     AND v_actor_is_elite_producer = false THEN
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

  v_new_is_exclusive := COALESCE(
    NULLIF(COALESCE(p_new_data->>'is_exclusive', ''), '')::boolean,
    v_source.is_exclusive
  );
  v_new_product_type := CASE
    WHEN v_new_is_exclusive THEN 'exclusive'::public.product_type
    ELSE 'beat'::public.product_type
  END;

  v_root_id := COALESCE(v_source.parent_product_id, v_source.id);

  PERFORM 1
  FROM public.products
  WHERE COALESCE(parent_product_id, id) = v_root_id
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
    AND deleted_at IS NULL
  FOR UPDATE;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_version
  FROM public.products
  WHERE COALESCE(parent_product_id, id) = v_root_id
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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
    v_new_product_type,
    COALESCE(NULLIF(COALESCE(p_new_data->>'genre_id', ''), '')::uuid, v_source.genre_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'mood_id', ''), '')::uuid, v_source.mood_id),
    COALESCE(NULLIF(COALESCE(p_new_data->>'bpm', ''), '')::integer, v_source.bpm),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'key_signature', '')), ''), v_source.key_signature),
    COALESCE(NULLIF(COALESCE(p_new_data->>'price', ''), '')::integer, v_source.price),
    COALESCE(NULLIF(btrim(COALESCE(p_new_data->>'cover_image_url', '')), ''), v_source.cover_image_url),
    v_new_is_exclusive,
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
  WHERE COALESCE(parent_product_id, id) = v_root_id
    AND status = 'active'
    AND product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
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

REVOKE EXECUTE ON FUNCTION public.enqueue_audio_processing_job(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_edit_product(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_archive_product(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enqueue_audio_processing_job(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_audio_processing_job(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() TO authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() TO service_role;
GRANT EXECUTE ON FUNCTION public.can_edit_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_edit_product(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_archive_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_archive_product(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_delete_product_if_no_sales(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_publish_product_version(uuid, jsonb) TO service_role;

COMMIT;
