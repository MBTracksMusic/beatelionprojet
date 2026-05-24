/*
  # 262 — Fix auth header on email pipeline cron jobs
  See supabase/migrations/20260524182000_262_fix_email_pipeline_cron_auth.sql
*/

BEGIN;

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
    RAISE EXCEPTION 'vault.project_url is missing.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._reschedule_pipeline_worker(
  p_jobname  text,
  p_endpoint text,
  p_schedule text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_job_id bigint;
BEGIN
  SELECT jobid INTO v_existing_job_id FROM cron.job WHERE jobname = p_jobname LIMIT 1;

  IF v_existing_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing_job_id);
    RAISE NOTICE 'Unscheduled existing job % (id %).', p_jobname, v_existing_job_id;
  END IF;

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
      SELECT decrypted_secret FROM vault.decrypted_secrets
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

  RAISE NOTICE 'Scheduled job % targeting %.', p_jobname, p_endpoint;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._reschedule_pipeline_worker(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._reschedule_pipeline_worker(text, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public._reschedule_pipeline_worker(text, text, text) FROM authenticated;

SELECT public._reschedule_pipeline_worker(
  'process-outbox-every-minute',      'process-outbox',      '* * * * *'
);
SELECT public._reschedule_pipeline_worker(
  'process-events-every-minute',      'process-events',      '* * * * *'
);
SELECT public._reschedule_pipeline_worker(
  'process-email-queue-every-minute', 'process-email-queue', '* * * * *'
);

DROP FUNCTION public._reschedule_pipeline_worker(text, text, text);

COMMIT;
