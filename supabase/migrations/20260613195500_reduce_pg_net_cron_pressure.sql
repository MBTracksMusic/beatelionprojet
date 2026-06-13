/*
  # Reduce pg_net and cron pressure

  The production database audit showed that the remaining hot path is not a
  front-office business query but repeated internal pg_cron + pg_net activity:

  - process-outbox, process-events and process-email-queue run every 2 minutes.
  - net._http_response cleanup dominates SQL time because every pg_net call
    writes a response row and the extension rotates those rows frequently.

  This keeps the same workers, endpoints, auth headers and payloads, but lowers
  cadence from every 2 minutes to every 5 minutes. It also adds a lightweight
  SQL-only retention job for pg_net responses so Supabase's own 6h cleanup has
  little or nothing left to delete.
*/

BEGIN;

DO $$
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE EXCEPTION 'cron schema is missing.';
  END IF;

  IF to_regnamespace('net') IS NULL THEN
    RAISE EXCEPTION 'net schema is missing.';
  END IF;

  IF to_regnamespace('vault') IS NULL THEN
    RAISE EXCEPTION 'vault schema is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) THEN
    RAISE EXCEPTION 'vault.project_url or vault.supabase_url is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name = 'internal_pipeline_secret'
  ) THEN
    RAISE EXCEPTION 'vault.internal_pipeline_secret is missing.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._schedule_internal_worker_cron_5min(
  p_jobname text,
  p_endpoint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM cron.schedule(
    p_jobname,
    '*/5 * * * *',
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

REVOKE EXECUTE ON FUNCTION public._schedule_internal_worker_cron_5min(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._schedule_internal_worker_cron_5min(text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public._schedule_internal_worker_cron_5min(text, text) FROM authenticated;

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
      'process-email-queue-every-2-minutes',
      'process-outbox-every-5-minutes',
      'process-events-every-5-minutes',
      'process-email-queue-every-5-minutes'
    )
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
END;
$$;

SELECT public._schedule_internal_worker_cron_5min(
  'process-outbox-every-5-minutes',
  'process-outbox'
);

SELECT public._schedule_internal_worker_cron_5min(
  'process-events-every-5-minutes',
  'process-events'
);

SELECT public._schedule_internal_worker_cron_5min(
  'process-email-queue-every-5-minutes',
  'process-email-queue'
);

DROP FUNCTION public._schedule_internal_worker_cron_5min(text, text);

CREATE OR REPLACE FUNCTION public.cleanup_pg_net_http_response_retention(
  p_keep interval DEFAULT interval '1 hour',
  p_limit integer DEFAULT 1000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted integer := 0;
  v_effective_keep interval := COALESCE(p_keep, interval '1 hour');
  v_effective_limit integer := COALESCE(p_limit, 1000);
BEGIN
  IF to_regclass('net._http_response') IS NULL THEN
    RETURN jsonb_build_object(
      'deleted', 0,
      'skipped', true,
      'reason', 'net._http_response missing'
    );
  END IF;

  IF v_effective_keep < interval '15 minutes' THEN
    v_effective_keep := interval '15 minutes';
  END IF;

  v_effective_limit := LEAST(GREATEST(v_effective_limit, 1), 5000);

  WITH deleted AS (
    DELETE FROM net._http_response r
    WHERE r.ctid IN (
      SELECT h.ctid
      FROM net._http_response h
      WHERE h.created < clock_timestamp() - v_effective_keep
      ORDER BY h.created
      LIMIT v_effective_limit
    )
    RETURNING 1
  )
  SELECT count(*)::integer
  INTO v_deleted
  FROM deleted;

  RETURN jsonb_build_object(
    'deleted', v_deleted,
    'keep', v_effective_keep::text,
    'limit', v_effective_limit
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.cleanup_pg_net_http_response_retention(interval, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cleanup_pg_net_http_response_retention(interval, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.cleanup_pg_net_http_response_retention(interval, integer) FROM authenticated;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid
  INTO v_job_id
  FROM cron.job
  WHERE jobname = 'cleanup-pg-net-http-response-15min'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'cleanup-pg-net-http-response-15min',
    '*/15 * * * *',
    $cron$SELECT public.cleanup_pg_net_http_response_retention(interval '1 hour', 1000);$cron$
  );
END;
$$;

SELECT public.cleanup_pg_net_http_response_retention(interval '1 hour', 5000);

COMMENT ON FUNCTION public.cleanup_pg_net_http_response_retention(interval, integer)
IS 'Trims pg_net response rows earlier than the extension default retention to reduce net._http_response cleanup churn.';

COMMIT;
