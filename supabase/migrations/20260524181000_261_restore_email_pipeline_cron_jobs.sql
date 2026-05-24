/*
  # 261 — Restore email pipeline cron jobs missing in production

  See supabase/migrations/20260524181000_261_restore_email_pipeline_cron_jobs.sql
*/

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) THEN
    RAISE EXCEPTION 'vault.project_url (or vault.supabase_url) is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE lower(name) IN ('service_role_key', 'supabase_service_role_key')
  ) THEN
    RAISE EXCEPTION 'vault.service_role_key (or vault.supabase_service_role_key) is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'schedule_service_role_worker_cron'
  ) THEN
    RAISE EXCEPTION 'Helper public.schedule_service_role_worker_cron is missing. Migration 175 must be applied first.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public._schedule_worker_if_missing(
  p_jobname  text,
  p_endpoint text,
  p_schedule text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = p_jobname) THEN
    RAISE NOTICE 'Cron job % already exists, skipping (idempotent).', p_jobname;
    RETURN;
  END IF;

  PERFORM public.schedule_service_role_worker_cron(p_jobname, p_endpoint, p_schedule);
  RAISE NOTICE 'Scheduled cron job %.', p_jobname;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._schedule_worker_if_missing(text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._schedule_worker_if_missing(text, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public._schedule_worker_if_missing(text, text, text) FROM authenticated;

SELECT public._schedule_worker_if_missing(
  'process-outbox-every-minute',       'process-outbox',       '* * * * *'
);
SELECT public._schedule_worker_if_missing(
  'process-events-every-minute',       'process-events',       '* * * * *'
);
SELECT public._schedule_worker_if_missing(
  'process-email-queue-every-minute',  'process-email-queue',  '* * * * *'
);
SELECT public._schedule_worker_if_missing(
  'repair-email-delivery-every-15min', 'repair-email-delivery', '*/15 * * * *'
);

DROP FUNCTION public._schedule_worker_if_missing(text, text, text);

COMMIT;
