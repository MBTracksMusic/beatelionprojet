/*
  # Bootstrap pipeline scheduler (vault secrets + cron workers)

  Why:
  - The event-driven email pipeline relies on 3 workers executed by pg_cron.
  - In some environments, cron jobs are missing because canonical Vault secret
    names (`project_url`, `service_role_key`) were not present.

  What:
  - Ensure required extensions exist: pg_cron, pg_net, vault, pgcrypto.
  - Bootstrap canonical scheduler secrets from known aliases when available.
  - Recreate worker cron jobs for:
    - process-outbox
    - process-events
    - process-email-queue
  - Add a safe manual worker invocation helper for operational testing.
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Required extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_available_extensions
    WHERE name = 'vault'
  ) THEN
    CREATE EXTENSION IF NOT EXISTS vault;
  ELSIF to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Vault extension package is unavailable and schema "vault" is missing.';
  ELSE
    RAISE NOTICE 'Vault extension package is unavailable, but schema "vault" already exists.';
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2) Canonical Vault secret bootstrap for scheduler
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_pipeline_scheduler_secrets(
  p_project_url text DEFAULT NULL,
  p_service_role_key text DEFAULT NULL
)
RETURNS TABLE(project_url_set boolean, service_role_key_set boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_project_url text;
  v_service_role_key text;
BEGIN
  IF to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping scheduler secret bootstrap: vault extension unavailable.';
    RETURN QUERY SELECT false, false;
    RETURN;
  END IF;

  -- Priority: explicit param -> canonical secret -> alias secret.
  v_project_url := NULLIF(btrim(p_project_url), '');
  IF v_project_url IS NULL THEN
    SELECT NULLIF(btrim(decrypted_secret), '')
    INTO v_project_url
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('project_url', 'supabase_url')
    ORDER BY CASE
      WHEN lower(name) = 'project_url' THEN 0
      WHEN lower(name) = 'supabase_url' THEN 1
      ELSE 9
    END
    LIMIT 1;
  END IF;

  v_service_role_key := NULLIF(btrim(p_service_role_key), '');
  IF v_service_role_key IS NULL THEN
    SELECT NULLIF(btrim(decrypted_secret), '')
    INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE lower(name) IN ('service_role_key', 'supabase_service_role_key')
    ORDER BY CASE
      WHEN lower(name) = 'service_role_key' THEN 0
      WHEN lower(name) = 'supabase_service_role_key' THEN 1
      ELSE 9
    END
    LIMIT 1;
  END IF;

  IF v_project_url IS NOT NULL THEN
    DELETE FROM vault.secrets
    WHERE lower(name) = 'project_url';

    BEGIN
      PERFORM vault.create_secret(v_project_url, 'project_url');
    EXCEPTION
      WHEN undefined_function THEN
        -- Compatibility if create_secret requires description parameter.
        PERFORM vault.create_secret(v_project_url, 'project_url', 'Pipeline scheduler project URL');
    END;
  ELSE
    RAISE NOTICE 'Scheduler secret bootstrap: project_url remains missing.';
  END IF;

  IF v_service_role_key IS NOT NULL THEN
    DELETE FROM vault.secrets
    WHERE lower(name) = 'service_role_key';

    BEGIN
      PERFORM vault.create_secret(v_service_role_key, 'service_role_key');
    EXCEPTION
      WHEN undefined_function THEN
        -- Compatibility if create_secret requires description parameter.
        PERFORM vault.create_secret(v_service_role_key, 'service_role_key', 'Pipeline scheduler service role key');
    END;
  ELSE
    RAISE NOTICE 'Scheduler secret bootstrap: service_role_key remains missing.';
  END IF;

  RETURN QUERY SELECT v_project_url IS NOT NULL, v_service_role_key IS NOT NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.ensure_pipeline_scheduler_secrets(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.ensure_pipeline_scheduler_secrets(text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.ensure_pipeline_scheduler_secrets(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_pipeline_scheduler_secrets(text, text) TO service_role;

-- Try to bootstrap canonical names from existing aliases when possible.
SELECT public.ensure_pipeline_scheduler_secrets();

-- -----------------------------------------------------------------------------
-- 3) Recreate core worker cron jobs
-- -----------------------------------------------------------------------------
SELECT public.schedule_service_role_worker_cron('process-outbox-every-minute', 'process-outbox', '* * * * *');
SELECT public.schedule_service_role_worker_cron('process-events-every-minute', 'process-events', '* * * * *');
SELECT public.schedule_service_role_worker_cron('process-email-queue-every-minute', 'process-email-queue', '* * * * *');

-- -----------------------------------------------------------------------------
-- 4) Manual worker trigger helper (ops)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.invoke_pipeline_worker(p_endpoint text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_endpoint text;
  v_project_url text;
  v_service_role_key text;
  v_request_id bigint;
BEGIN
  v_endpoint := NULLIF(btrim(p_endpoint), '');
  IF v_endpoint IS NULL THEN
    RAISE EXCEPTION 'Worker endpoint is required';
  END IF;

  SELECT rtrim(decrypted_secret, '/')
  INTO v_project_url
  FROM vault.decrypted_secrets
  WHERE lower(name) IN ('project_url', 'supabase_url')
  ORDER BY CASE
    WHEN lower(name) = 'project_url' THEN 0
    WHEN lower(name) = 'supabase_url' THEN 1
    ELSE 9
  END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE lower(name) IN ('service_role_key', 'supabase_service_role_key')
  ORDER BY CASE
    WHEN lower(name) = 'service_role_key' THEN 0
    WHEN lower(name) = 'supabase_service_role_key' THEN 1
    ELSE 9
  END
  LIMIT 1;

  IF v_project_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE EXCEPTION 'Missing scheduler secrets (project_url/service_role_key).';
  END IF;

  SELECT net.http_post(
    url := v_project_url || '/functions/v1/' || v_endpoint,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_role_key
    ),
    body := '{}'::jsonb
  )
  INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.invoke_pipeline_worker(text) TO service_role;

COMMIT;
