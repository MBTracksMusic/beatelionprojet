/*
  # 260 — Fix corrupted agent-finalize-expired-battles cron job

  See supabase/migrations/20260524180000_260_fix_finalize_expired_battles_cron_prod.sql
*/

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets WHERE name = 'agent_cron_secret'
  ) THEN
    RAISE EXCEPTION 'vault.agent_cron_secret is missing. Create it in Supabase Dashboard > Settings > Vault before applying this migration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
  ) THEN
    RAISE EXCEPTION 'vault.project_url (or vault.supabase_url) is missing. Create it in Supabase Dashboard > Settings > Vault before applying this migration.';
  END IF;
END;
$$;

DO $$
BEGIN
  PERFORM cron.unschedule('agent-finalize-expired-battles');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

SELECT cron.schedule(
  'agent-finalize-expired-battles',
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
    ) || '/functions/v1/agent-finalize-expired-battles',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret FROM vault.decrypted_secrets
        WHERE name = 'agent_cron_secret'
        LIMIT 1
      )
    ),
    body := '{}'::jsonb
  );
  $cron$
);

COMMIT;
