/*
  # Phase 4: pipeline metrics, observability, and direct-handlers preparation

  Objectifs:
  - preparer la transition outbox -> handlers directs
  - ajouter des metriques de pipeline exploitables en production
  - fournir des primitives SQL de monitoring et d'alerting
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Metrics storage
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.pipeline_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component text NOT NULL,
  metric_name text NOT NULL,
  metric_value numeric,
  labels jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pipeline_metrics_component_metric_created_idx
  ON public.pipeline_metrics (component, metric_name, created_at DESC);

CREATE INDEX IF NOT EXISTS pipeline_metrics_created_at_idx
  ON public.pipeline_metrics (created_at DESC);

ALTER TABLE public.pipeline_metrics ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.pipeline_metrics FROM anon;
REVOKE ALL ON TABLE public.pipeline_metrics FROM authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.pipeline_metrics TO service_role;

DROP POLICY IF EXISTS "Service role can manage pipeline metrics" ON public.pipeline_metrics;
CREATE POLICY "Service role can manage pipeline metrics"
ON public.pipeline_metrics
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

COMMENT ON TABLE public.pipeline_metrics IS
  'Time-series metrics for event/email pipeline observability (outbox, bus, queue, latency, backlog).';

-- -----------------------------------------------------------------------------
-- 2) Prepare direct_handlers path by linking email_queue directly to outbox
-- -----------------------------------------------------------------------------

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS source_outbox_id uuid REFERENCES public.event_outbox(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS email_queue_source_outbox_unique_idx
  ON public.email_queue (source_outbox_id)
  WHERE source_outbox_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS email_queue_source_outbox_idx
  ON public.email_queue (source_outbox_id)
  WHERE source_outbox_id IS NOT NULL;

-- Backfill source_outbox_id from existing source_event_id links when possible.
UPDATE public.email_queue eq
SET source_outbox_id = eb.source_outbox_id
FROM public.event_bus eb
WHERE eq.source_outbox_id IS NULL
  AND eq.source_event_id = eb.id
  AND eb.source_outbox_id IS NOT NULL;

-- Guard event-driven emails: at least one stable source id must be present.
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
  AND NEW.source_event_id IS NULL
  AND NEW.source_outbox_id IS NULL THEN
    RAISE EXCEPTION 'event_email_requires_source_reference';
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
-- 3) Snapshot + health + alerts SQL APIs
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.pipeline_backlog_snapshot()
RETURNS TABLE (
  event_outbox_pending bigint,
  event_bus_pending bigint,
  email_queue_pending bigint,
  email_queue_failed bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    (SELECT count(*) FROM public.event_outbox WHERE status = 'pending') AS event_outbox_pending,
    (SELECT count(*) FROM public.event_bus WHERE status = 'pending') AS event_bus_pending,
    (SELECT count(*) FROM public.email_queue WHERE status = 'pending') AS email_queue_pending,
    (SELECT count(*) FROM public.email_queue WHERE status = 'failed') AS email_queue_failed;
$$;

REVOKE EXECUTE ON FUNCTION public.pipeline_backlog_snapshot() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pipeline_backlog_snapshot() FROM anon;
REVOKE EXECUTE ON FUNCTION public.pipeline_backlog_snapshot() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pipeline_backlog_snapshot() TO service_role;

CREATE OR REPLACE VIEW public.pipeline_health
WITH (security_invoker = true)
AS
WITH backlog AS (
  SELECT *
  FROM public.pipeline_backlog_snapshot()
),
latency AS (
  SELECT COALESCE(avg(EXTRACT(EPOCH FROM (eq.processed_at - eo.created_at)) * 1000.0), 0)::numeric AS avg_latency
  FROM public.email_queue eq
  LEFT JOIN public.event_bus eb
    ON eb.id = eq.source_event_id
  LEFT JOIN public.event_outbox eo
    ON eo.id = COALESCE(eq.source_outbox_id, eb.source_outbox_id)
  WHERE eq.status = 'sent'
    AND eq.processed_at IS NOT NULL
    AND eo.created_at IS NOT NULL
    AND eq.processed_at >= now() - interval '1 hour'
),
throughput AS (
  SELECT COALESCE(count(*)::numeric / 5.0, 0)::numeric AS events_per_minute
  FROM public.event_outbox eo
  WHERE eo.status = 'processed'
    AND eo.processed_at IS NOT NULL
    AND eo.processed_at >= now() - interval '5 minute'
)
SELECT
  b.event_outbox_pending::numeric AS outbox_backlog,
  b.email_queue_pending::numeric AS email_queue_backlog,
  b.email_queue_failed::numeric AS failed_emails,
  l.avg_latency,
  t.events_per_minute
FROM backlog b
CROSS JOIN latency l
CROSS JOIN throughput t;

REVOKE ALL ON TABLE public.pipeline_health FROM PUBLIC;
REVOKE ALL ON TABLE public.pipeline_health FROM anon;
REVOKE ALL ON TABLE public.pipeline_health FROM authenticated;
GRANT SELECT ON TABLE public.pipeline_health TO service_role;

CREATE OR REPLACE FUNCTION public.pipeline_alerts()
RETURNS TABLE (
  alert_key text,
  severity text,
  current_value numeric,
  threshold numeric,
  is_alert boolean,
  details jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH health AS (
    SELECT * FROM public.pipeline_health
  )
  SELECT
    'email_queue_failed'::text AS alert_key,
    'high'::text AS severity,
    h.failed_emails AS current_value,
    50::numeric AS threshold,
    (h.failed_emails > 50)::boolean AS is_alert,
    jsonb_build_object('component', 'email_queue', 'metric', 'failed_emails') AS details
  FROM health h

  UNION ALL

  SELECT
    'pipeline_latency_ms'::text AS alert_key,
    'high'::text AS severity,
    h.avg_latency AS current_value,
    10000::numeric AS threshold,
    (h.avg_latency > 10000)::boolean AS is_alert,
    jsonb_build_object('component', 'pipeline', 'metric', 'avg_latency_ms') AS details
  FROM health h

  UNION ALL

  SELECT
    'event_outbox_pending'::text AS alert_key,
    'critical'::text AS severity,
    h.outbox_backlog AS current_value,
    500::numeric AS threshold,
    (h.outbox_backlog > 500)::boolean AS is_alert,
    jsonb_build_object('component', 'event_outbox', 'metric', 'pending_backlog') AS details
  FROM health h;
$$;

REVOKE EXECUTE ON FUNCTION public.pipeline_alerts() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pipeline_alerts() FROM anon;
REVOKE EXECUTE ON FUNCTION public.pipeline_alerts() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.pipeline_alerts() TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Enrich audit trail for direct handlers and metrics phase
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
LEFT JOIN LATERAL (
  SELECT eq1.*
  FROM public.email_queue eq1
  WHERE eq1.source_outbox_id = eo.id
     OR eq1.source_event_id = COALESCE(eo.event_id, eb.id)
  ORDER BY
    CASE WHEN eq1.source_outbox_id = eo.id THEN 0 ELSE 1 END,
    eq1.created_at DESC
  LIMIT 1
) eq ON true;

REVOKE ALL ON TABLE public.event_audit_log FROM PUBLIC;
REVOKE ALL ON TABLE public.event_audit_log FROM anon;
REVOKE ALL ON TABLE public.event_audit_log FROM authenticated;
GRANT SELECT ON TABLE public.event_audit_log TO service_role;

-- -----------------------------------------------------------------------------
-- 5) Cron metrics collection
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_job_name text := 'collect-pipeline-metrics-every-minute';
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL OR to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for collect-pipeline-metrics.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key') THEN
    RAISE NOTICE 'Skipping cron setup for collect-pipeline-metrics: missing vault secrets.';
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
        ) || '/functions/v1/collect-pipeline-metrics',
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

COMMIT;
