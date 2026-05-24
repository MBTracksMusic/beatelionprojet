/*
  # 263 — Fix auth header on repair-email-delivery cron job
  See supabase/migrations/20260524183000_263_fix_repair_email_delivery_cron_auth.sql
*/

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets WHERE name = 'email_repair_secret'
  ) THEN
    RAISE EXCEPTION 'vault.email_repair_secret is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) THEN
    RAISE EXCEPTION 'vault.project_url is missing.';
  END IF;
END;
$$;

DO $$
DECLARE
  v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid
  FROM cron.job
  WHERE jobname = 'repair-email-delivery-every-15min'
  LIMIT 1;

  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
    RAISE NOTICE 'Unscheduled existing repair-email-delivery-every-15min (id %).', v_jobid;
  END IF;
END;
$$;

SELECT cron.schedule(
  'repair-email-delivery-every-15min',
  '*/15 * * * *',
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
    ) || '/functions/v1/repair-email-delivery',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-email-repair-secret', (
        SELECT decrypted_secret FROM vault.decrypted_secrets
        WHERE name = 'email_repair_secret'
        LIMIT 1
      )
    ),
    body := '{}'::jsonb
  );
  $cron$
);

COMMIT;
