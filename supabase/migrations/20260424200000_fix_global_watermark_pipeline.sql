/*
  # Stabilize global watermark processing

  - Treat disabled/missing watermark settings as a queue pause: workers should
    not claim jobs until an active watermark sample is configured.
  - Restore signature-aware global reprocess enqueueing for beat and exclusive
    audio products.
  - Keep preview_version ownership in SQL: enqueue/reprocess advances the target
    version, workers render exactly that version.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.compute_watermark_hash_v2(
  p_watermark_audio_path text,
  p_gain_db numeric,
  p_min_interval_sec integer,
  p_max_interval_sec integer,
  p_updated_at timestamptz
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT encode(
    extensions.digest(
      concat_ws(
        '|',
        COALESCE(p_watermark_audio_path, ''),
        public.format_watermark_gain_db(p_gain_db),
        COALESCE(p_min_interval_sec, 0)::text,
        COALESCE(p_max_interval_sec, 0)::text,
        CASE
          WHEN p_updated_at IS NULL THEN ''
          ELSE to_char(p_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        END
      ),
      'sha256'
    ),
    'hex'
  );
$$;

CREATE OR REPLACE FUNCTION public.claim_audio_processing_jobs(
  p_limit integer DEFAULT 20,
  p_worker text DEFAULT NULL
)
RETURNS SETOF public.audio_processing_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', '');
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_worker text := COALESCE(NULLIF(btrim(COALESCE(p_worker, '')), ''), 'audio-worker');
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_or_service_role_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.site_audio_settings sas
    WHERE sas.enabled = true
      AND NULLIF(btrim(COALESCE(sas.watermark_audio_path, '')), '') IS NOT NULL
    ORDER BY sas.updated_at DESC, sas.created_at DESC, sas.id DESC
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH reclaimed AS (
    UPDATE public.audio_processing_jobs AS stale
    SET
      status = 'queued',
      locked_at = NULL,
      locked_by = NULL,
      updated_at = now()
    WHERE stale.status = 'processing'
      AND stale.locked_at IS NOT NULL
      AND stale.locked_at < now() - interval '15 minutes'
    RETURNING stale.id
  ),
  candidates AS (
    SELECT job.id
    FROM public.audio_processing_jobs AS job
    WHERE job.status IN ('queued', 'error')
      AND job.attempts < job.max_attempts
    ORDER BY job.created_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  ),
  claimed AS (
    UPDATE public.audio_processing_jobs AS job
    SET
      status = 'processing',
      attempts = job.attempts + 1,
      locked_at = now(),
      locked_by = v_worker,
      updated_at = now()
    FROM candidates
    WHERE job.id = candidates.id
    RETURNING job.*
  )
  SELECT * FROM claimed;
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
  v_settings record;
  v_candidate_count integer := 0;
  v_enqueued_count integer := 0;
  v_skipped_count integer := 0;
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT
    NULLIF(btrim(COALESCE(sas.watermark_audio_path, '')), '') AS watermark_audio_path,
    COALESCE(sas.gain_db, -10.00) AS gain_db,
    COALESCE(sas.min_interval_sec, 20) AS min_interval_sec,
    COALESCE(sas.max_interval_sec, 45) AS max_interval_sec,
    public.compute_watermark_hash_v2(
      NULLIF(btrim(COALESCE(sas.watermark_audio_path, '')), ''),
      COALESCE(sas.gain_db, -10.00),
      COALESCE(sas.min_interval_sec, 20),
      COALESCE(sas.max_interval_sec, 45),
      sas.updated_at
    ) AS current_watermark_hash
  INTO v_settings
  FROM public.site_audio_settings sas
  WHERE sas.enabled = true
    AND NULLIF(btrim(COALESCE(sas.watermark_audio_path, '')), '') IS NOT NULL
  ORDER BY sas.updated_at DESC, sas.created_at DESC, sas.id DESC
  LIMIT 1;

  IF NOT FOUND OR v_settings.watermark_audio_path IS NULL THEN
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
  )
  SELECT COUNT(*) INTO v_candidate_count
  FROM candidate_products;

  WITH scannable_products AS (
    SELECT
      p.id,
      p.preview_signature,
      p.last_watermark_hash,
      p.watermarked_path,
      p.preview_url,
      p.exclusive_preview_url,
      public.compute_preview_signature(
        COALESCE(
          NULLIF(btrim(COALESCE(p.master_path, '')), ''),
          NULLIF(btrim(COALESCE(p.master_url, '')), '')
        ),
        v_settings.watermark_audio_path,
        v_settings.gain_db,
        v_settings.min_interval_sec,
        v_settings.max_interval_sec
      ) AS current_preview_signature
    FROM public.products p
    WHERE p.product_type IN ('beat'::public.product_type, 'exclusive'::public.product_type)
      AND p.is_published = true
      AND p.deleted_at IS NULL
      AND COALESCE(
        NULLIF(btrim(COALESCE(p.master_path, '')), ''),
        NULLIF(btrim(COALESCE(p.master_url, '')), '')
      ) IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.audio_processing_jobs job
        WHERE job.product_id = p.id
          AND job.job_type = 'generate_preview'
          AND job.status IN ('queued', 'processing')
      )
  ),
  eligible_products AS (
    SELECT sp.id
    FROM scannable_products sp
    WHERE sp.preview_signature IS NULL
      OR sp.last_watermark_hash IS DISTINCT FROM v_settings.current_watermark_hash
      OR sp.preview_signature IS DISTINCT FROM sp.current_preview_signature
      OR COALESCE(
        NULLIF(btrim(COALESCE(sp.watermarked_path, '')), ''),
        NULLIF(btrim(COALESCE(sp.preview_url, '')), ''),
        NULLIF(btrim(COALESCE(sp.exclusive_preview_url, '')), '')
      ) IS NULL
  ),
  inserted_jobs AS (
    INSERT INTO public.audio_processing_jobs (product_id, job_type, status)
    SELECT ep.id, 'generate_preview', 'queued'
    FROM eligible_products ep
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

  v_skipped_count := GREATEST(v_candidate_count - v_enqueued_count, 0);

  RETURN jsonb_build_object(
    'enqueued_count', v_enqueued_count,
    'skipped_count', v_skipped_count
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.compute_watermark_hash_v2(text, numeric, integer, integer, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_audio_processing_jobs(integer, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.compute_watermark_hash_v2(text, numeric, integer, integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_audio_processing_jobs(integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_audio_processing_jobs(integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() TO authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_reprocess_all_previews() TO service_role;

COMMIT;
