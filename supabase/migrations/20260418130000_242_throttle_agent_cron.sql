-- Slow down agent-auto-execute-ai-actions from every 5 min to every 15 min
-- Reduces CPU pressure from heavy PL/pgSQL battle action processing on production

BEGIN;

DO $$
BEGIN
  PERFORM cron.unschedule('agent-auto-execute-ai-actions');
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'agent-auto-execute-ai-actions',
  '*/15 * * * *',
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
