# Pipeline Internal Secrets Rotation

## Scope

This runbook covers rotation of internal pipeline secrets used by Supabase Edge Functions and pg_cron callers:

- `INTERNAL_PIPELINE_SECRET`
- `PIPELINE_HEALTH_SECRET`
- `PIPELINE_METRICS_SECRET`
- `PIPELINE_COLLECTOR_SECRET`
- `EVENT_REPLAY_SECRET`
- `EMAIL_REPAIR_SECRET`

Vault names used by SQL scheduler:

- `internal_pipeline_secret`
- `pipeline_health_secret`
- `pipeline_metrics_secret`
- `pipeline_collector_secret`
- `event_replay_secret`
- `email_repair_secret`
- `project_url`

## Rotation Strategy (v1 -> v2)

1. Create v2 values in secret manager:
   - Example: `INTERNAL_PIPELINE_SECRET_V2`
2. Deploy code accepting both v1 and v2:
   - Accept request if header matches either value.
3. Update callers:
   - Edge secrets
   - Vault secrets used by scheduler
   - Internal manual callers
4. Validate traffic:
   - No 401 increase
   - Workers still return 200
5. Remove v1 support from code.
6. Delete v1 secrets from all environments.

## Safe Rollout Order

1. Generate new secrets.
2. Set Edge Function secrets (v2) without removing v1.
3. Set Vault secrets used by cron/internal SQL invokers.
4. Deploy dual-accept code.
5. Run runtime checks:
   - no header => 401
   - wrong secret => 401
   - v1 => 200
   - v2 => 200
6. Switch all callers to v2.
7. Remove v1 from code and secret stores.

## Runtime Validation Checklist

- `process-outbox` returns `200` with current secret.
- `process-events` returns `200` with current secret.
- `process-email-queue` returns `200` with current secret.
- `collect-pipeline-metrics` returns `200` with current secret.
- `repair-email-delivery` returns `200` with current secret.
- `pipeline-health` returns `200` with current secret.
- `pipeline-metrics` returns `200` with current secret.
- `replay-events` returns `200` with current secret.

## Rollback

If error rate spikes after cutover:

1. Restore v1 values in Edge secrets and Vault.
2. Keep dual-accept logic enabled.
3. Re-run runtime validation.
4. Investigate caller still using outdated header/value.

## Operational Notes

- Never log raw secret values.
- Never pass service role bearer as a transport secret.
- Keep `verify_jwt = false` only for internal/public functions that use dedicated gates.
- Rotation should be executed first in staging, then production.
