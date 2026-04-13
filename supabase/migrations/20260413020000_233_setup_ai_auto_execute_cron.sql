/*
  # Setup pg_cron job for agent-auto-execute-ai-actions

  Creates a Supabase Vault secret to store the AGENT_CRON_SECRET,
  then schedules a pg_cron job that calls the Edge Function every 5 minutes
  via pg_net. The secret is read from Vault at runtime — never hardcoded.

  ⚠️  After applying this migration, update the Vault secret with the real value:
      SELECT vault.update_secret('<secret-uuid>', '<YOUR_REAL_AGENT_CRON_SECRET>');
      (find the UUID with: SELECT id FROM vault.secrets WHERE name = 'agent_cron_secret')
*/

BEGIN;

-- ── 1. Create Vault secret (placeholder — update after deploy) ───────────────
DO $$
DECLARE
  v_existing_id uuid;
BEGIN
  SELECT id INTO v_existing_id
  FROM vault.secrets
  WHERE name = 'agent_cron_secret'
  LIMIT 1;

  IF v_existing_id IS NULL THEN
    PERFORM vault.create_secret(
      'PLACEHOLDER_UPDATE_REQUIRED',
      'agent_cron_secret',
      'AGENT_CRON_SECRET used by pg_cron to authenticate the agent-auto-execute-ai-actions Edge Function'
    );
  END IF;
END;
$$;

-- ── 2. Remove existing job if present (idempotent) ───────────────────────────
DO $$
BEGIN
  PERFORM cron.unschedule('agent-auto-execute-ai-actions');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
$$;

-- ── 3. Schedule the cron job (every 5 minutes) ───────────────────────────────
SELECT cron.schedule(
  'agent-auto-execute-ai-actions',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url     := 'https://ftcyybcbaqxyrombfmqp.supabase.co/functions/v1/agent-auto-execute-ai-actions',
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
