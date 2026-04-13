/*
  # Setup pg_cron job for agent-finalize-expired-battles

  Schedules a pg_cron job that calls the Edge Function every 15 minutes
  via pg_net. Reuses the existing Vault secret 'agent_cron_secret'
  (same secret as agent-auto-execute-ai-actions).

  No new Vault secret needed — the existing 'agent_cron_secret' is shared
  between both agent cron jobs.
*/

BEGIN;

-- ── 1. Remove existing job if present (idempotent) ───────────────────────────
DO $$
BEGIN
  PERFORM cron.unschedule('agent-finalize-expired-battles');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
$$;

-- ── 2. Schedule the cron job (every 15 minutes) ──────────────────────────────
SELECT cron.schedule(
  'agent-finalize-expired-battles',
  '*/15 * * * *',
  $$
  SELECT net.http_post(
    url     := 'https://ftcyybcbaqxyrombfmqp.supabase.co/functions/v1/agent-finalize-expired-battles',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        SELECT decrypted_secret
        FROM vault.decrypted_secrets
        WHERE name = 'agent_cron_secret'
        LIMIT 1
      )
    ),
    body    := '{}'::jsonb
  );
  $$
);

COMMIT;
