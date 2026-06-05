/*
  # Reduce pipeline Disk IO churn

  The email/event pipeline must keep running for business-critical flows
  such as purchases, forum/battle notifications and transactional emails.
  This migration keeps the workers active but reduces background churn:

  - Replace one-minute pg_cron jobs with two-minute jobs.
  - Add a daily retention function for noisy observability tables.
  - Keep old job names unscheduled so replays are idempotent.
*/

BEGIN;

-- Required by the worker cron commands.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets WHERE name = 'internal_pipeline_secret'
  ) THEN
    RAISE EXCEPTION 'vault.internal_pipeline_secret is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) THEN
    RAISE EXCEPTION 'vault.project_url or vault.supabase_url is missing.';
  END IF;
END;
$$;

-- Unschedule old and replacement job names before scheduling the canonical set.
DO $$
DECLARE
  v_job_id bigint;
BEGIN
  FOR v_job_id IN
    SELECT jobid
    FROM cron.job
    WHERE jobname IN (
      'process-outbox-every-minute',
      'process-events-every-minute',
      'process-email-queue-every-minute',
      'process-outbox-every-2-minutes',
      'process-events-every-2-minutes',
      'process-email-queue-every-2-minutes'
    )
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public._schedule_pipeline_worker_disk_io(
  p_jobname text,
  p_endpoint text,
  p_schedule text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM cron.schedule(
    p_jobname,
    p_schedule,
    format(
$cron$
SELECT net.http_post(
  url := (
    SELECT rtrim(decrypted_secret, '/')
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
    ORDER BY CASE
      WHEN lower(name) = 'project_url' THEN 0
      WHEN lower(name) = 'supabase_url' THEN 1
      ELSE 9
    END
    LIMIT 1
  ) || '/functions/v1/%s',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'x-internal-secret', (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE name = 'internal_pipeline_secret'
      LIMIT 1
    )
  ),
  body := '{}'::jsonb
);
$cron$,
      p_endpoint
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public._schedule_pipeline_worker_disk_io(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._schedule_pipeline_worker_disk_io(text, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public._schedule_pipeline_worker_disk_io(text, text, text) FROM authenticated;

SELECT public._schedule_pipeline_worker_disk_io(
  'process-outbox-every-2-minutes',
  'process-outbox',
  '*/2 * * * *'
);

SELECT public._schedule_pipeline_worker_disk_io(
  'process-events-every-2-minutes',
  'process-events',
  '*/2 * * * *'
);

SELECT public._schedule_pipeline_worker_disk_io(
  'process-email-queue-every-2-minutes',
  'process-email-queue',
  '*/2 * * * *'
);

DROP FUNCTION public._schedule_pipeline_worker_disk_io(text, text, text);

CREATE OR REPLACE FUNCTION public.cleanup_pipeline_observability_retention()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron, pg_temp
AS $$
DECLARE
  v_metrics_deleted integer := 0;
  v_zero_alerts_deleted integer := 0;
  v_old_alerts_deleted integer := 0;
  v_cron_rows_deleted integer := 0;
BEGIN
  DELETE FROM public.pipeline_metrics
  WHERE created_at < now() - interval '7 days';
  GET DIAGNOSTICS v_metrics_deleted = ROW_COUNT;

  DELETE FROM public.monitoring_alert_events
  WHERE event_type = 'pipeline_worker_zero_processed_streak'
    AND created_at < now() - interval '1 day';
  GET DIAGNOSTICS v_zero_alerts_deleted = ROW_COUNT;

  DELETE FROM public.monitoring_alert_events
  WHERE event_type IS DISTINCT FROM 'pipeline_worker_zero_processed_streak'
    AND created_at < now() - interval '30 days'
    AND (resolved_at IS NOT NULL OR severity IN ('info', 'warning'));
  GET DIAGNOSTICS v_old_alerts_deleted = ROW_COUNT;

  DELETE FROM cron.job_run_details
  WHERE start_time < now() - interval '14 days';
  GET DIAGNOSTICS v_cron_rows_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'pipeline_metrics_deleted', v_metrics_deleted,
    'zero_processed_alerts_deleted', v_zero_alerts_deleted,
    'old_alerts_deleted', v_old_alerts_deleted,
    'cron_job_run_details_deleted', v_cron_rows_deleted
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.cleanup_pipeline_observability_retention() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cleanup_pipeline_observability_retention() FROM anon;
REVOKE EXECUTE ON FUNCTION public.cleanup_pipeline_observability_retention() FROM authenticated;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid
  INTO v_job_id
  FROM cron.job
  WHERE jobname = 'cleanup-pipeline-observability-daily'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'cleanup-pipeline-observability-daily',
    '23 3 * * *',
    'SELECT public.cleanup_pipeline_observability_retention();'
  );
END;
$$;

COMMIT;
