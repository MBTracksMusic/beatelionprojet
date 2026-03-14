/*
  # Enterprise event-driven hardening: outbox, replay, repair, audit

  Phases couvertes:
  - Phase 1: event_outbox ajoute, publish_event ecrit aussi dans outbox
  - Phase 2: process-outbox disponible pour synchroniser vers event_bus
  - Phase 3: replay/repair/audit disponibles
  - Phase 4: event_bus conserve pour compatibilite transitoire
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) event_outbox (source de verite rejouable)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.event_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid UNIQUE REFERENCES public.event_bus(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  aggregate_type text,
  aggregate_id uuid,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_table text,
  source_record_id uuid,
  dedupe_key text,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 10,
  last_error text,
  locked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  replayed_from_event_id uuid REFERENCES public.event_outbox(id) ON DELETE SET NULL,
  replay_reason text
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_outbox_status_check'
      AND conrelid = 'public.event_outbox'::regclass
  ) THEN
    ALTER TABLE public.event_outbox
      ADD CONSTRAINT event_outbox_status_check
      CHECK (status IN ('pending', 'processing', 'processed', 'failed'));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_outbox_event_type_check'
      AND conrelid = 'public.event_outbox'::regclass
  ) THEN
    ALTER TABLE public.event_outbox
      ADD CONSTRAINT event_outbox_event_type_check
      CHECK (
        event_type IN (
          'USER_SIGNUP',
          'USER_CONFIRMED',
          'PRODUCER_ACTIVATED',
          'BEAT_PURCHASED',
          'LICENSE_GENERATED',
          'BATTLE_WON',
          'COMMENT_RECEIVED'
        )
      );
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS event_outbox_status_idx
  ON public.event_outbox (status, created_at);

CREATE INDEX IF NOT EXISTS event_outbox_event_type_idx
  ON public.event_outbox (event_type, created_at DESC);

CREATE INDEX IF NOT EXISTS event_outbox_user_id_idx
  ON public.event_outbox (user_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS event_outbox_dedupe_key_unique_idx
  ON public.event_outbox (dedupe_key)
  WHERE dedupe_key IS NOT NULL;

ALTER TABLE public.event_outbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.event_outbox FROM anon;
REVOKE ALL ON TABLE public.event_outbox FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.event_outbox TO service_role;

DROP POLICY IF EXISTS "Service role can manage event outbox" ON public.event_outbox;
CREATE POLICY "Service role can manage event outbox"
ON public.event_outbox
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- event_bus remains for compatibility; source_outbox_id links transitional sync.
ALTER TABLE public.event_bus
  ADD COLUMN IF NOT EXISTS source_outbox_id uuid REFERENCES public.event_outbox(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS event_bus_source_outbox_unique_idx
  ON public.event_bus (source_outbox_id)
  WHERE source_outbox_id IS NOT NULL;

-- Replay support requires duplicates on same aggregate; outbox/source_event dedupe now controls idempotence.
DROP INDEX IF EXISTS event_bus_event_aggregate_unique_idx;
CREATE INDEX IF NOT EXISTS event_bus_event_aggregate_idx
  ON public.event_bus (event_type, aggregate_id);

-- -----------------------------------------------------------------------------
-- 2) Replay requests
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.event_replay_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  aggregate_type text,
  aggregate_id uuid,
  from_date timestamptz,
  to_date timestamptz,
  status text NOT NULL DEFAULT 'pending',
  requested_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  replay_count integer NOT NULL DEFAULT 0,
  last_error text
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_replay_requests_status_check'
      AND conrelid = 'public.event_replay_requests'::regclass
  ) THEN
    ALTER TABLE public.event_replay_requests
      ADD CONSTRAINT event_replay_requests_status_check
      CHECK (status IN ('pending', 'processed', 'failed'));
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS event_replay_requests_status_idx
  ON public.event_replay_requests (status, created_at DESC);

CREATE INDEX IF NOT EXISTS event_replay_requests_event_type_idx
  ON public.event_replay_requests (event_type, created_at DESC);

ALTER TABLE public.event_replay_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.event_replay_requests FROM anon;
REVOKE ALL ON TABLE public.event_replay_requests FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.event_replay_requests TO service_role;

DROP POLICY IF EXISTS "Service role can manage event replay requests" ON public.event_replay_requests;
CREATE POLICY "Service role can manage event replay requests"
ON public.event_replay_requests
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 3) Publish helpers + claims
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publish_outbox_event(
  p_event_type text,
  p_user_id uuid,
  p_aggregate_type text,
  p_aggregate_id uuid,
  p_payload jsonb,
  p_source_table text DEFAULT NULL,
  p_source_record_id uuid DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL
)
RETURNS public.event_outbox
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_type text := upper(COALESCE(NULLIF(btrim(p_event_type), ''), ''));
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_dedupe_key text := NULLIF(btrim(COALESCE(p_dedupe_key, '')), '');
  v_row public.event_outbox%ROWTYPE;
BEGIN
  IF v_event_type = '' THEN
    RAISE EXCEPTION 'event_type_required';
  END IF;

  IF v_dedupe_key IS NULL THEN
    v_dedupe_key := md5(
      concat_ws(
        '|',
        v_event_type,
        COALESCE(NULLIF(btrim(p_aggregate_type), ''), ''),
        COALESCE(p_aggregate_id::text, ''),
        COALESCE(p_user_id::text, ''),
        COALESCE(NULLIF(btrim(p_source_table), ''), ''),
        COALESCE(p_source_record_id::text, '')
      )
    );
  END IF;

  INSERT INTO public.event_outbox (
    event_type,
    aggregate_type,
    aggregate_id,
    user_id,
    payload,
    source_table,
    source_record_id,
    dedupe_key,
    status
  )
  VALUES (
    v_event_type,
    NULLIF(btrim(COALESCE(p_aggregate_type, '')), ''),
    p_aggregate_id,
    p_user_id,
    v_payload,
    NULLIF(btrim(COALESCE(p_source_table, '')), ''),
    p_source_record_id,
    v_dedupe_key,
    'pending'
  )
  ON CONFLICT (dedupe_key) DO UPDATE
    SET dedupe_key = EXCLUDED.dedupe_key
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.publish_outbox_event(text, uuid, text, uuid, jsonb, text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.publish_outbox_event(text, uuid, text, uuid, jsonb, text, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.publish_outbox_event(text, uuid, text, uuid, jsonb, text, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.publish_outbox_event(text, uuid, text, uuid, jsonb, text, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.publish_event(
  p_event_type text,
  p_user_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_event_type text := upper(COALESCE(NULLIF(btrim(p_event_type), ''), ''));
  v_aggregate_type text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_type', '')), '');
  v_aggregate_id uuid;
  v_event_id uuid;
  v_outbox public.event_outbox%ROWTYPE;
  v_source_table text := NULLIF(btrim(COALESCE(v_payload->>'source_table', v_payload->>'source', '')), '');
  v_source_record_id uuid;
  v_dedupe_key text := NULLIF(btrim(COALESCE(v_payload->>'dedupe_key', '')), '');
  v_aggregate_id_text text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_id', '')), '');
  v_source_record_id_text text := NULLIF(btrim(COALESCE(v_payload->>'source_record_id', '')), '');
BEGIN
  IF v_event_type = '' THEN
    RAISE EXCEPTION 'event_type_required';
  END IF;

  IF v_aggregate_id_text IS NOT NULL THEN
    BEGIN
      v_aggregate_id := v_aggregate_id_text::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_aggregate_id := NULL;
    END;
  END IF;

  IF v_source_record_id_text IS NOT NULL THEN
    BEGIN
      v_source_record_id := v_source_record_id_text::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_source_record_id := NULL;
    END;
  END IF;

  IF v_aggregate_id IS NULL AND p_user_id IS NOT NULL
    AND v_event_type IN ('USER_SIGNUP', 'USER_CONFIRMED', 'PRODUCER_ACTIVATED') THEN
    v_aggregate_id := p_user_id;
    IF v_aggregate_type IS NULL THEN
      v_aggregate_type := 'user';
    END IF;
  END IF;

  v_outbox := public.publish_outbox_event(
    p_event_type => v_event_type,
    p_user_id => p_user_id,
    p_aggregate_type => v_aggregate_type,
    p_aggregate_id => v_aggregate_id,
    p_payload => v_payload,
    p_source_table => v_source_table,
    p_source_record_id => v_source_record_id,
    p_dedupe_key => v_dedupe_key
  );

  IF v_outbox.event_id IS NOT NULL THEN
    RETURN v_outbox.event_id;
  END IF;

  INSERT INTO public.event_bus (
    event_type,
    aggregate_type,
    aggregate_id,
    user_id,
    payload,
    status,
    source_outbox_id
  )
  VALUES (
    v_event_type,
    v_aggregate_type,
    v_aggregate_id,
    p_user_id,
    v_payload || jsonb_build_object('outbox_id', v_outbox.id),
    'pending',
    v_outbox.id
  )
  ON CONFLICT (source_outbox_id) DO UPDATE
    SET source_outbox_id = EXCLUDED.source_outbox_id
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT eb.id
    INTO v_event_id
    FROM public.event_bus eb
    WHERE eb.source_outbox_id = v_outbox.id
    ORDER BY eb.created_at DESC
    LIMIT 1;
  END IF;

  IF v_event_id IS NULL THEN
    SELECT eb.id
    INTO v_event_id
    FROM public.event_bus eb
    WHERE eb.event_type = v_event_type
      AND eb.aggregate_id IS NOT DISTINCT FROM v_aggregate_id
      AND eb.user_id IS NOT DISTINCT FROM p_user_id
    ORDER BY eb.created_at DESC
    LIMIT 1;
  END IF;

  IF v_event_id IS NOT NULL THEN
    UPDATE public.event_outbox
    SET event_id = v_event_id
    WHERE id = v_outbox.id
      AND event_id IS NULL;
  END IF;

  RETURN v_event_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_outbox_batch(
  p_limit integer DEFAULT 50,
  p_reclaim_after_seconds integer DEFAULT 600
)
RETURNS SETOF public.event_outbox
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_reclaim_seconds integer := GREATEST(60, COALESCE(p_reclaim_after_seconds, 600));
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT eo.id
    FROM public.event_outbox eo
    WHERE (
      eo.status = 'pending'
      OR (
        eo.status = 'processing'
        AND eo.locked_at IS NOT NULL
        AND eo.locked_at <= now() - make_interval(secs => v_reclaim_seconds)
      )
    )
      AND eo.attempts < eo.max_attempts
    ORDER BY eo.created_at ASC
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.event_outbox eo
    SET
      status = 'processing',
      locked_at = now(),
      last_error = NULL
    FROM candidates c
    WHERE eo.id = c.id
    RETURNING eo.*
  )
  SELECT *
  FROM claimed
  ORDER BY created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_outbox_batch(integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_outbox_batch(integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_outbox_batch(integer, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.claim_outbox_batch(integer, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Audit trail view
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.event_audit_log
WITH (security_invoker = true)
AS
SELECT
  eo.id AS outbox_id,
  COALESCE(eo.event_id, eb.id) AS event_id,
  eo.event_type,
  eo.user_id,
  eo.aggregate_type,
  eo.aggregate_id,
  eo.status AS outbox_status,
  eb.status AS event_bus_status,
  eq.template AS email_template,
  eq.status AS email_status,
  eo.created_at,
  eo.processed_at,
  eo.replayed_from_event_id,
  eo.replay_reason
FROM public.event_outbox eo
LEFT JOIN LATERAL (
  SELECT eb1.*
  FROM public.event_bus eb1
  WHERE eb1.source_outbox_id = eo.id
     OR (eo.event_id IS NOT NULL AND eb1.id = eo.event_id)
  ORDER BY
    CASE WHEN eb1.source_outbox_id = eo.id THEN 0 ELSE 1 END,
    eb1.created_at DESC
  LIMIT 1
) eb ON true
LEFT JOIN public.email_queue eq
  ON eq.source_event_id = COALESCE(eo.event_id, eb.id);

REVOKE ALL ON TABLE public.event_audit_log FROM PUBLIC;
REVOKE ALL ON TABLE public.event_audit_log FROM anon;
REVOKE ALL ON TABLE public.event_audit_log FROM authenticated;
GRANT SELECT ON TABLE public.event_audit_log TO service_role;

-- -----------------------------------------------------------------------------
-- 5) Cron jobs (outbox + optional repair dry-run)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_job_name text := 'process-outbox-every-minute';
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL OR to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for process-outbox.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key') THEN
    RAISE NOTICE 'Skipping cron setup for process-outbox: missing vault secrets.';
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
        ) || '/functions/v1/process-outbox',
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
END
$$;

DO $$
DECLARE
  v_job_name text := 'repair-email-delivery-daily-dry-run';
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL OR to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for repair-email-delivery dry-run.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key') THEN
    RAISE NOTICE 'Skipping cron setup for repair-email-delivery dry-run: missing vault secrets.';
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
    '15 3 * * *',
    $cron$
      SELECT net.http_post(
        url := (
          SELECT rtrim(decrypted_secret, '/')
          FROM vault.decrypted_secrets
          WHERE name = 'project_url'
          LIMIT 1
        ) || '/functions/v1/repair-email-delivery',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = 'service_role_key'
            LIMIT 1
          )
        ),
        body := jsonb_build_object(
          'dry_run', true,
          'execute', false
        )
      );
    $cron$
  );
END
$$;

COMMIT;
