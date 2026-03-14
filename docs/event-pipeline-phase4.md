# Event Pipeline Phase 4 (BeatElion)

## 1) Architecture simplifiee et progressive

Architecture en production (compatible phase 1->4):

1. tables metier
2. `publish_event(...)`
3. `event_outbox`
4. `process-outbox`
5. `event_bus` (mode compatibilite)
6. `process-events`
7. `email_queue`
8. `process-email-queue`
9. Resend

Evolution phase 4:

- `process-outbox` supporte maintenant deux modes via `EVENT_PIPELINE_MODE`:
  - `compatibility` (defaut): outbox -> event_bus -> process-events
  - `direct_handlers`: outbox -> handlers directs -> email_queue
- Le mode `direct_handlers` prepare la suppression future de `event_bus` sans casser le pipeline actuel.

## 2) Feature flag `EVENT_PIPELINE_MODE`

Variable d'environnement serveur:

- `EVENT_PIPELINE_MODE=compatibility` (defaut)
- `EVENT_PIPELINE_MODE=direct_handlers`

Comportement:

- `compatibility`: comportement historique conserve.
- `direct_handlers`: `process-outbox` execute les handlers email directement, en utilisant `email_queue.source_outbox_id` comme reference principale.

## 3) Strategie d'idempotence (phase 4)

- Outbox: `dedupe_key` unique (hors NULL).
- Bus: `source_outbox_id` unique.
- Queue:
  - `source_event_id` unique (compatibilite)
  - `source_outbox_id` unique (nouveau chemin direct)
  - singletons `confirm_account`, `welcome_user`, `producer_activation` uniques par `(user_id, template)`
- Guard rail DB:
  - un email evenementiel requiert au moins une source (`source_event_id` ou `source_outbox_id`).

## 4) Metrics et observabilite

Nouvelle table: `public.pipeline_metrics`

Champs:

- `component`
- `metric_name`
- `metric_value`
- `labels`
- `created_at`

Workers instrumentes:

- `process-outbox`
- `process-events`
- `process-email-queue`

Metriques collecteables:

- `events_processed`
- `events_failed`
- `email_sent`
- `email_failed`
- `pipeline_latency_ms`
- `queue_backlog`

## 5) Monitoring SQL

Nouvelles primitives:

- `public.pipeline_backlog_snapshot()`
  - `event_outbox_pending`
  - `event_bus_pending`
  - `email_queue_pending`
  - `email_queue_failed`

- vue `public.pipeline_health`
  - `outbox_backlog`
  - `email_queue_backlog`
  - `failed_emails`
  - `avg_latency`
  - `events_per_minute`

- fonction `public.pipeline_alerts()`
  - alerte si `email_queue_failed > 50`
  - alerte si `avg_latency > 10000 ms`
  - alerte si `event_outbox_pending > 500`

## 6) Ops endpoints (service-role only)

- `GET /functions/v1/pipeline-health`
- `GET /functions/v1/pipeline-metrics`
- `POST /functions/v1/repair-email-delivery`
- `POST /functions/v1/replay-events`
- `POST /functions/v1/collect-pipeline-metrics`

## 7) Cron jobs

Ajout phase 4:

- `collect-pipeline-metrics-every-minute` -> `collect-pipeline-metrics`

Cron existants conserves:

- `process-outbox-every-minute`
- `process-events-every-minute` (tant que mode compatibilite)
- `process-email-queue-every-minute`
- `repair-email-delivery-daily-dry-run`

## 8) Plan suppression event_bus (future)

1. Basculer d'abord `EVENT_PIPELINE_MODE=direct_handlers` en staging.
2. Verifier l'absence de regression via `pipeline_health` + `pipeline_alerts`.
3. Basculer progressivement la prod.
4. Quand stable: marquer `process-events` et `event_bus` comme secondaires.
5. Supprimer `event_bus` dans une migration ulterieure dediee.

## 9) Limites connues

- La collecte metrique est orientee operationnel SQL (pas encore dashboard UI).
- En mode `compatibility`, la latence end-to-end depend encore de la chaine outbox->bus->queue.
- `repair-email-delivery` reste un outil puissant reserve service-role.
