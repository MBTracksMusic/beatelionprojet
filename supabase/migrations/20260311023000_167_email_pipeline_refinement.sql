/*
  # Email/Event pipeline refinement (enterprise hardening)

  Objectifs:
  - raffiner l'idempotence email_queue (singletons vs repeatables)
  - ajouter des garde-fous contre les doubles chemins d'insertion
  - enrichir le diagnostic/audit du pipeline outbox -> bus -> email_queue
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Idempotence email_queue: singles vs repeatables
-- -----------------------------------------------------------------------------

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS source_event_id uuid REFERENCES public.event_bus(id) ON DELETE SET NULL;

-- Retire la contrainte trop large historique.
DROP INDEX IF EXISTS public.email_queue_user_template_unique_idx;

-- Les templates singletons restent uniques par user.
CREATE UNIQUE INDEX IF NOT EXISTS email_queue_user_template_singleton_unique_idx
  ON public.email_queue (user_id, template)
  WHERE user_id IS NOT NULL
    AND template IN ('confirm_account', 'welcome_user', 'producer_activation');

-- L'idempotence principale des emails evenementiels reste basee sur l'evenement source.
CREATE UNIQUE INDEX IF NOT EXISTS email_queue_source_event_unique_idx
  ON public.email_queue (source_event_id)
  WHERE source_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS email_queue_template_status_created_idx
  ON public.email_queue (template, status, created_at DESC);

-- -----------------------------------------------------------------------------
-- 2) Metadonnees de repair
-- -----------------------------------------------------------------------------

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS repair_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS last_repair_at timestamptz;

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS repair_reason text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'email_queue_repair_count_non_negative'
      AND conrelid = 'public.email_queue'::regclass
  ) THEN
    ALTER TABLE public.email_queue
      ADD CONSTRAINT email_queue_repair_count_non_negative
      CHECK (repair_count >= 0);
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS email_queue_last_repair_at_idx
  ON public.email_queue (last_repair_at DESC)
  WHERE last_repair_at IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 3) Garde-fou: un email evenementiel doit avoir un source_event_id
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guard_event_email_queue_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.template IN (
    'confirm_account',
    'welcome_user',
    'producer_activation',
    'purchase_receipt',
    'license_ready',
    'battle_won',
    'comment_received'
  )
  AND NEW.source_event_id IS NULL THEN
    RAISE EXCEPTION 'event_email_requires_source_event_id';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_event_email_queue_insert ON public.email_queue;
CREATE TRIGGER trg_guard_event_email_queue_insert
  BEFORE INSERT ON public.email_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_event_email_queue_insert();

-- -----------------------------------------------------------------------------
-- 4) Audit trail enrichi
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
  eo.created_at AS created_at,
  eo.processed_at AS processed_at,
  eo.replayed_from_event_id,
  eo.replay_reason,
  eo.attempts AS outbox_attempts,
  eo.last_error AS outbox_last_error,
  eb.attempts AS event_bus_attempts,
  eb.last_error AS event_bus_last_error,
  eq.attempts AS email_attempts,
  eq.last_error AS email_last_error,
  eq.repair_count AS email_repair_count,
  eq.last_repair_at AS email_last_repair_at,
  eq.repair_reason AS email_repair_reason,
  eo.created_at AS outbox_created_at,
  eo.processed_at AS outbox_processed_at,
  eb.created_at AS event_bus_created_at,
  eb.processed_at AS event_bus_processed_at,
  eq.created_at AS email_created_at,
  eq.processed_at AS email_processed_at
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

COMMIT;
