# BeatElion Email Event Architecture

## 1) Architecture actuelle

Pipeline transactionnel email (phase transitoire outbox -> bus):

1. Tables metier publient un evenement via `publish_event(...)`.
2. `publish_event(...)` ecrit d'abord dans `public.event_outbox` (source de verite), puis synchronise `public.event_bus` pour compatibilite.
3. `process-outbox` claim des evenements outbox et garantit le relai vers `event_bus`.
4. `process-events` transforme les evenements en jobs `public.email_queue`.
5. `process-email-queue` envoie via Resend.

## 2) Role de `event_outbox`

`event_outbox` est la source fiable des evenements metier:

- persistance initiale avant traitement;
- idempotence via `dedupe_key`;
- support replay (`replayed_from_event_id`, `replay_reason`);
- support audit (`status`, `attempts`, `last_error`, `processed_at`).

## 3) Role transitoire de `event_bus`

`event_bus` reste actif pour la migration progressive:

- consommation par `process-events` existant;
- lien explicite avec outbox via `source_outbox_id`;
- compatibilite ascendante sans casser les handlers existants.

Cible long terme: execution des handlers directement depuis outbox, avec `event_bus` secondaire puis deprecie.

## 4) Role de `email_queue`

`email_queue` porte l'execution des emails:

- claim concurrent-safe (`claim_email_queue_batch`);
- retries (`attempts`, `max_attempts`);
- diagnostic (`last_error`, `locked_at`);
- metadonnees de repair (`repair_count`, `last_repair_at`, `repair_reason`).

## 5) Strategie d'idempotence

## Evenements

- `event_outbox.dedupe_key` unique (si non null).
- `event_bus.source_outbox_id` unique pour eviter un double relai bus.

## Emails

- idempotence principale: `email_queue.source_event_id` unique.
- templates singletons (`confirm_account`, `welcome_user`, `producer_activation`): unicite partielle `(user_id, template)`.
- templates repeatables (`purchase_receipt`, `license_ready`, `comment_received`, `battle_won`): autorises plusieurs fois si `source_event_id` differente.

## Guard rail anti double chemin

Un trigger DB bloque tout insert d'email evenementiel sans `source_event_id`:

- empêche les anciens chemins SQL/Edge non controles;
- force le chemin principal `process-events` (ou `repair-email-delivery` controle).

## 6) Strategie replay

`replay-events`:

- service-role only;
- filtres: `event_type`, `user_id`, `aggregate_type`, `aggregate_id`, plage de dates;
- creation de nouveaux evenements outbox (les originaux ne sont jamais modifies);
- dedupe replay dediee pour eviter collisions avec l'evenement d'origine.

## 7) Strategie repair

`repair-email-delivery` fonctionne en outbox-first:

- source principale: `event_outbox.status = processed`;
- `event_bus` est utilise pour diagnostic secondaire et backfill de `event_outbox.event_id`;
- modes:
  - `dry_run` (par defaut): diagnostic uniquement;
  - `execute`: applique les actions.
- strategies ciblees:
  - `requeue`: remet en file les emails `failed` / `stale processing`;
  - `recreate`: recree les emails manquants depuis l'event source;
  - `replay`: cree un replay outbox pour les evenements sans relai email possible;
  - `auto`: combine les 3 strategies.

Filtres de securite pour limiter l'impact:

- `event_type`
- `user_id`
- `aggregate_id`
- `source_event_id`
- `from_date` / `to_date`
- `limit`

## 8) Stale locks

Strategie homogene sur outbox/bus/email:

- timeout stale lock: `600s`;
- fenetre d'execution active worker: `45s`;
- constantes partagees dans `supabase/functions/_shared/eventPipelineConfig.ts`.

## 9) Audit trail

La vue `event_audit_log` expose:

- statut/attempts/errors outbox;
- statut/attempts/errors event_bus;
- statut/attempts/errors email;
- metadonnees replay (`replayed_from_event_id`, `replay_reason`);
- metadonnees repair (`repair_count`, `last_repair_at`, `repair_reason`).

## 10) Limites actuelles

- Les handlers emails sont encore executes via `event_bus` (et pas directement depuis outbox).
- `repair-email-delivery` est un chemin secondaire volontairement controle (service-role only + strategies ciblees).
- L'observabilite est SQL-centric (vue d'audit), sans dashboard applicatif dedie.

## 11) Chemin cible long terme (Phase 4)

1. Migrer les handlers pour consommer directement `event_outbox`.
2. Garder `event_bus` comme projection de compatibilite puis le rendre optionnel.
3. Ajouter un dashboard d'operations (replay/repair/audit) avec RBAC admin.
4. Ajouter des metriques de latence/erreur par event type et template.
