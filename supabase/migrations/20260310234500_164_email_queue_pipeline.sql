/*
  # Email queue pipeline (signup -> queue -> worker -> Resend)

  Objectifs:
  - ajouter une file d'emails transactionnels robuste et idempotente
  - alimenter la file via triggers SQL sur auth.users et public.user_profiles
  - fournir une primitive SQL de claim batch pour worker Edge Function
  - planifier un cron toutes les minutes vers l'Edge Function `process-email-queue`
*/

BEGIN;

-- 1) Queue d'emails transactionnels
CREATE TABLE IF NOT EXISTS public.email_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL,
  template text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  locked_at timestamptz,
  last_error text
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'email_queue_status_check'
      AND conrelid = 'public.email_queue'::regclass
  ) THEN
    ALTER TABLE public.email_queue
      ADD CONSTRAINT email_queue_status_check
      CHECK (status IN ('pending', 'processing', 'sent', 'failed'));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'email_queue_attempts_non_negative'
      AND conrelid = 'public.email_queue'::regclass
  ) THEN
    ALTER TABLE public.email_queue
      ADD CONSTRAINT email_queue_attempts_non_negative
      CHECK (attempts >= 0);
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'email_queue_max_attempts_positive'
      AND conrelid = 'public.email_queue'::regclass
  ) THEN
    ALTER TABLE public.email_queue
      ADD CONSTRAINT email_queue_max_attempts_positive
      CHECK (max_attempts > 0);
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS email_queue_status_idx
  ON public.email_queue (status);

CREATE INDEX IF NOT EXISTS email_queue_created_idx
  ON public.email_queue (created_at);

CREATE INDEX IF NOT EXISTS email_queue_status_created_idx
  ON public.email_queue (status, created_at);

-- Idempotence: un template transactionnel ne doit etre queue qu'une seule fois par user.
CREATE UNIQUE INDEX IF NOT EXISTS email_queue_user_template_unique_idx
  ON public.email_queue (user_id, template);

ALTER TABLE public.email_queue ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.email_queue FROM anon;
REVOKE ALL ON TABLE public.email_queue FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.email_queue TO service_role;

DROP POLICY IF EXISTS "Service role can manage email queue" ON public.email_queue;
CREATE POLICY "Service role can manage email queue"
ON public.email_queue
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

COMMENT ON TABLE public.email_queue IS
  'Queue transactionnelle des emails applicatifs (confirm_account, welcome_user, producer_activation).';

-- 2) Trigger signup: auth.users -> confirm_account
CREATE OR REPLACE FUNCTION public.enqueue_signup_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
  v_email := lower(trim(COALESCE(NEW.email, '')));
  IF v_email = '' THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.email_queue (
    user_id,
    email,
    template,
    payload,
    status
  )
  VALUES (
    NEW.id,
    v_email,
    'confirm_account',
    jsonb_build_object(
      'source', 'auth.users',
      'trigger', 'on_auth_user_created_enqueue_signup_email'
    ),
    'pending'
  )
  ON CONFLICT (user_id, template) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_enqueue_signup_email ON auth.users;
CREATE TRIGGER on_auth_user_created_enqueue_signup_email
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.enqueue_signup_email();

-- 3) Trigger confirmation email: auth.users.email_confirmed_at -> welcome_user
CREATE OR REPLACE FUNCTION public.enqueue_welcome_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
  IF OLD.email_confirmed_at IS NOT NULL OR NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  v_email := lower(trim(COALESCE(NEW.email, '')));
  IF v_email = '' THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.email_queue (
    user_id,
    email,
    template,
    payload,
    status
  )
  VALUES (
    NEW.id,
    v_email,
    'welcome_user',
    jsonb_build_object(
      'source', 'auth.users',
      'trigger', 'on_auth_user_confirmed_enqueue_welcome_email'
    ),
    'pending'
  )
  ON CONFLICT (user_id, template) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_confirmed_enqueue_welcome_email ON auth.users;
CREATE TRIGGER on_auth_user_confirmed_enqueue_welcome_email
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW
  WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public.enqueue_welcome_email();

-- 4) Trigger activation producteur: user_profiles -> producer_activation
CREATE OR REPLACE FUNCTION public.enqueue_producer_activation_email()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_profile jsonb := to_jsonb(NEW);
  v_old_profile jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  v_email text;
  v_new_account_type text := lower(COALESCE(v_new_profile->>'account_type', ''));
  v_old_account_type text := lower(COALESCE(v_old_profile->>'account_type', ''));
  v_new_role text := lower(COALESCE(v_new_profile->>'role', ''));
  v_old_role text := lower(COALESCE(v_old_profile->>'role', ''));
  v_new_is_active boolean := lower(COALESCE(v_new_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_old_is_active boolean := lower(COALESCE(v_old_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_new_is_producer boolean;
  v_old_is_producer boolean;
BEGIN
  v_new_is_producer := v_new_account_type = 'producer' OR v_new_role = 'producer' OR v_new_is_active;
  v_old_is_producer := v_old_account_type = 'producer' OR v_old_role = 'producer' OR v_old_is_active;

  IF v_new_is_producer AND NOT v_old_is_producer THEN
    v_email := lower(trim(COALESCE(NEW.email, '')));

    IF v_email <> '' THEN
      INSERT INTO public.email_queue (
        user_id,
        email,
        template,
        payload,
        status
      )
      VALUES (
        NEW.id,
        v_email,
        'producer_activation',
        jsonb_build_object(
          'source', 'public.user_profiles',
          'trigger', 'on_user_profile_producer_activation_email',
          'producer_role', COALESCE(NULLIF(v_new_role, ''), NULLIF(v_new_account_type, ''))
        ),
        'pending'
      )
      ON CONFLICT (user_id, template) DO NOTHING;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_user_profile_producer_activation_email ON public.user_profiles;
CREATE TRIGGER on_user_profile_producer_activation_email
  AFTER INSERT OR UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enqueue_producer_activation_email();

-- 5) Primitive de claim batch pour worker (concurrence-safe + reclaim stale locks)
CREATE OR REPLACE FUNCTION public.claim_email_queue_batch(
  p_limit integer DEFAULT 20,
  p_reclaim_after_seconds integer DEFAULT 600
)
RETURNS SETOF public.email_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
  v_reclaim_seconds integer := GREATEST(60, COALESCE(p_reclaim_after_seconds, 600));
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT q.id
    FROM public.email_queue q
    WHERE (
      q.status = 'pending'
      OR (
        q.status = 'processing'
        AND q.locked_at IS NOT NULL
        AND q.locked_at <= now() - make_interval(secs => v_reclaim_seconds)
      )
    )
      AND q.attempts < q.max_attempts
    ORDER BY q.created_at ASC
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.email_queue q
    SET
      status = 'processing',
      locked_at = now(),
      last_error = NULL
    FROM candidates c
    WHERE q.id = c.id
    RETURNING q.*
  )
  SELECT *
  FROM claimed
  ORDER BY created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_email_queue_batch(integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_email_queue_batch(integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_email_queue_batch(integer, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.claim_email_queue_batch(integer, integer) TO service_role;

-- 6) Cron (toutes les minutes) -> Edge Function process-email-queue
--    Prerequis secrets Vault:
--    - project_url: https://<project-ref>.supabase.co
--    - service_role_key: <SUPABASE_SERVICE_ROLE_KEY>
DO $$
DECLARE
  v_job_name text := 'process-email-queue-every-minute';
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for process-email-queue: cron/net extensions unavailable.';
    RETURN;
  END IF;

  IF to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for process-email-queue: vault extension unavailable.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key') THEN
    RAISE NOTICE 'Skipping cron setup for process-email-queue: missing vault secrets project_url/service_role_key.';
    RETURN;
  END IF;

  SELECT jobid
  INTO v_existing_job_id
  FROM cron.job
  WHERE jobname = v_job_name
  LIMIT 1;

  IF v_existing_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing_job_id);
  END IF;

  PERFORM cron.schedule(
    v_job_name,
    '* * * * *',
    $cron$
      SELECT net.http_post(
        url := (
          SELECT rtrim(decrypted_secret, '/')
          FROM vault.decrypted_secrets
          WHERE name = 'project_url'
          LIMIT 1
        ) || '/functions/v1/process-email-queue',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = 'service_role_key'
            LIMIT 1
          )
        ),
        body := '{}'::jsonb
      );
    $cron$
  );
END;
$$;

COMMIT;
