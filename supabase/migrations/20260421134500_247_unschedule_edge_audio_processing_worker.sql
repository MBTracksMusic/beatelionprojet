/*
  # Unschedule Edge audio processing cron

  ## Why
  The temporary pg_cron fallback that calls `process-audio-jobs` proved that the
  queue was stalled, but fresh renders fail in the Edge runtime with:

    Worker is not defined

  This means the durable processing path must remain the native external
  `audio-worker`, not the FFmpeg.wasm Edge fallback.

  ## Fix
  Remove the temporary cron job so new uploads are not repeatedly retried by the
  incompatible Edge runtime while the native worker is being restored.
*/

BEGIN;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RETURN;
  END IF;

  SELECT jobid
  INTO v_job_id
  FROM cron.job
  WHERE jobname = 'process-audio-jobs-every-minute'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;
END;
$$;

COMMIT;
