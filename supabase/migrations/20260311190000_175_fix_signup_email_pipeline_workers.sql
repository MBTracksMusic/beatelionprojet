/*
  # Fix signup email pipeline reliability (outbox conflict + cron robustness)

  Why:
  - Signup succeeds but no email is sent when event pipeline cannot persist/forward events.
  - Several ON CONFLICT / upsert paths target columns backed by partial unique indexes,
    which can raise: "there is no unique or exclusion constraint matching the ON CONFLICT specification".
  - Cron setup previously required only `project_url` / `service_role_key` vault names.

  What:
  - Replace partial unique indexes used by ON CONFLICT/upsert with full unique indexes.
  - Ensure pg_cron + pg_net extensions exist.
  - Recreate core pipeline cron jobs with vault secret-name fallback:
    project_url|supabase_url and service_role_key|supabase_service_role_key.
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Ensure scheduler/network extensions exist
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- -----------------------------------------------------------------------------
-- 2) ON CONFLICT/upsert compatibility: replace partial unique indexes
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.event_outbox_dedupe_key_unique_idx;
CREATE UNIQUE INDEX IF NOT EXISTS event_outbox_dedupe_key_unique_idx
  ON public.event_outbox (dedupe_key);

DROP INDEX IF EXISTS public.event_bus_source_outbox_unique_idx;
CREATE UNIQUE INDEX IF NOT EXISTS event_bus_source_outbox_unique_idx
  ON public.event_bus (source_outbox_id);

DROP INDEX IF EXISTS public.email_queue_source_event_unique_idx;
CREATE UNIQUE INDEX IF NOT EXISTS email_queue_source_event_unique_idx
  ON public.email_queue (source_event_id);

DROP INDEX IF EXISTS public.email_queue_source_outbox_unique_idx;
CREATE UNIQUE INDEX IF NOT EXISTS email_queue_source_outbox_unique_idx
  ON public.email_queue (source_outbox_id);

-- -----------------------------------------------------------------------------
-- 3) Cron helper with vault fallback secret names
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.schedule_service_role_worker_cron(
  p_job_name text,
  p_endpoint text,
  p_schedule text DEFAULT '* * * * *'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
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

  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) OR NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('service_role_key', 'supabase_service_role_key')
  ) THEN
    RAISE NOTICE
      'Skipping cron setup for %: missing vault secrets project_url|supabase_url and service_role_key|supabase_service_role_key.',
      p_job_name;
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
    'Authorization', 'Bearer ' || (
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE lower(name) IN ('service_role_key', 'supabase_service_role_key')
      ORDER BY CASE
        WHEN lower(name) = 'service_role_key' THEN 0
        WHEN lower(name) = 'supabase_service_role_key' THEN 1
        ELSE 9
      END
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

REVOKE EXECUTE ON FUNCTION public.schedule_service_role_worker_cron(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.schedule_service_role_worker_cron(text, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.schedule_service_role_worker_cron(text, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_service_role_worker_cron(text, text, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Recreate core jobs
-- -----------------------------------------------------------------------------
SELECT public.schedule_service_role_worker_cron('process-outbox-every-minute', 'process-outbox', '* * * * *');
SELECT public.schedule_service_role_worker_cron('process-events-every-minute', 'process-events', '* * * * *');
SELECT public.schedule_service_role_worker_cron('process-email-queue-every-minute', 'process-email-queue', '* * * * *');

COMMIT;
