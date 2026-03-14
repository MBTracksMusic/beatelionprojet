/*
  # Harden internal pipeline auth gates and scheduler callers

  Why:
  - Internal workers previously relied on service-role bearer transport.
  - We now gate internal endpoints with dedicated secret headers.

  What:
  - Add a cron scheduling helper that sends dedicated internal secret headers.
  - Update the manual worker invoker to use endpoint-specific internal secrets.
  - Recreate internal cron jobs with the new headers.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.schedule_internal_secret_worker_cron(
  p_job_name text,
  p_endpoint text,
  p_schedule text DEFAULT '* * * * *',
  p_secret_header text DEFAULT 'x-internal-secret',
  p_secret_name text DEFAULT 'internal_pipeline_secret',
  p_body jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_project_url text;
  v_secret_value text;
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for %: cron/net extensions unavailable.', p_job_name;
    RETURN;
  END IF;

  IF to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for %: vault extension unavailable.', p_job_name;
    RETURN;
  END IF;

  SELECT rtrim(NULLIF(btrim(decrypted_secret), ''), '/')
  INTO v_project_url
  FROM vault.decrypted_secrets
  WHERE lower(name) IN ('project_url', 'supabase_url')
  ORDER BY CASE
    WHEN lower(name) = 'project_url' THEN 0
    WHEN lower(name) = 'supabase_url' THEN 1
    ELSE 9
  END
  LIMIT 1;

  IF v_project_url IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for %: missing vault secret project_url|supabase_url.', p_job_name;
    RETURN;
  END IF;

  SELECT NULLIF(btrim(decrypted_secret), '')
  INTO v_secret_value
  FROM vault.decrypted_secrets
  WHERE lower(name) = lower(p_secret_name)
  LIMIT 1;

  IF v_secret_value IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for %: missing vault secret "%".', p_job_name, p_secret_name;
    RETURN;
  END IF;

  SELECT jobid
  INTO v_existing_job_id
  FROM cron.job
  WHERE jobname = p_job_name
  LIMIT 1;

  IF v_existing_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing_job_id);
  END IF;

  PERFORM cron.schedule(
    p_job_name,
    p_schedule,
    format(
$cron$
SELECT net.http_post(
  url := %L,
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    %L, %L
  ),
  body := %L::jsonb
);
$cron$,
      v_project_url || '/functions/v1/' || p_endpoint,
      p_secret_header,
      v_secret_value,
      COALESCE(p_body, '{}'::jsonb)::text
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.schedule_internal_secret_worker_cron(text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.schedule_internal_secret_worker_cron(text, text, text, text, text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.schedule_internal_secret_worker_cron(text, text, text, text, text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_internal_secret_worker_cron(text, text, text, text, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.invoke_pipeline_worker(p_endpoint text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_endpoint text;
  v_project_url text;
  v_secret_name text;
  v_secret_header text;
  v_secret_value text;
  v_body jsonb := '{}'::jsonb;
  v_request_id bigint;
BEGIN
  v_endpoint := NULLIF(btrim(p_endpoint), '');
  IF v_endpoint IS NULL THEN
    RAISE EXCEPTION 'Worker endpoint is required';
  END IF;

  IF v_endpoint IN ('process-outbox', 'process-events', 'process-email-queue') THEN
    v_secret_name := 'internal_pipeline_secret';
    v_secret_header := 'x-internal-secret';
  ELSIF v_endpoint = 'collect-pipeline-metrics' THEN
    v_secret_name := 'pipeline_collector_secret';
    v_secret_header := 'x-pipeline-collector-secret';
  ELSIF v_endpoint = 'repair-email-delivery' THEN
    v_secret_name := 'email_repair_secret';
    v_secret_header := 'x-email-repair-secret';
    v_body := jsonb_build_object('dry_run', true, 'execute', false);
  ELSIF v_endpoint = 'replay-events' THEN
    v_secret_name := 'event_replay_secret';
    v_secret_header := 'x-event-replay-secret';
  ELSIF v_endpoint = 'pipeline-health' THEN
    v_secret_name := 'pipeline_health_secret';
    v_secret_header := 'x-pipeline-health-secret';
  ELSIF v_endpoint = 'pipeline-metrics' THEN
    v_secret_name := 'pipeline_metrics_secret';
    v_secret_header := 'x-pipeline-metrics-secret';
  ELSE
    RAISE EXCEPTION 'Unsupported internal endpoint: %', v_endpoint;
  END IF;

  SELECT rtrim(NULLIF(btrim(decrypted_secret), ''), '/')
  INTO v_project_url
  FROM vault.decrypted_secrets
  WHERE lower(name) IN ('project_url', 'supabase_url')
  ORDER BY CASE
    WHEN lower(name) = 'project_url' THEN 0
    WHEN lower(name) = 'supabase_url' THEN 1
    ELSE 9
  END
  LIMIT 1;

  IF v_project_url IS NULL THEN
    RAISE EXCEPTION 'Missing scheduler secret (project_url|supabase_url).';
  END IF;

  SELECT NULLIF(btrim(decrypted_secret), '')
  INTO v_secret_value
  FROM vault.decrypted_secrets
  WHERE lower(name) = lower(v_secret_name)
  LIMIT 1;

  IF v_secret_value IS NULL THEN
    RAISE EXCEPTION 'Missing scheduler secret (%).', v_secret_name;
  END IF;

  SELECT net.http_post(
    url := v_project_url || '/functions/v1/' || v_endpoint,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      v_secret_header, v_secret_value
    ),
    body := v_body
  )
  INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) TO service_role;

SELECT public.schedule_internal_secret_worker_cron(
  'process-outbox-every-minute',
  'process-outbox',
  '* * * * *',
  'x-internal-secret',
  'internal_pipeline_secret',
  '{}'::jsonb
);

SELECT public.schedule_internal_secret_worker_cron(
  'process-events-every-minute',
  'process-events',
  '* * * * *',
  'x-internal-secret',
  'internal_pipeline_secret',
  '{}'::jsonb
);

SELECT public.schedule_internal_secret_worker_cron(
  'process-email-queue-every-minute',
  'process-email-queue',
  '* * * * *',
  'x-internal-secret',
  'internal_pipeline_secret',
  '{}'::jsonb
);

SELECT public.schedule_internal_secret_worker_cron(
  'collect-pipeline-metrics-every-minute',
  'collect-pipeline-metrics',
  '* * * * *',
  'x-pipeline-collector-secret',
  'pipeline_collector_secret',
  '{}'::jsonb
);

SELECT public.schedule_internal_secret_worker_cron(
  'repair-email-delivery-daily-dry-run',
  'repair-email-delivery',
  '15 3 * * *',
  'x-email-repair-secret',
  'email_repair_secret',
  jsonb_build_object('dry_run', true, 'execute', false)
);

COMMIT;
