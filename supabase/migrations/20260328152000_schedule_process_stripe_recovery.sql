BEGIN;

SELECT public.schedule_internal_secret_worker_cron(
  'process-stripe-recovery-every-minute',
  'process-stripe-recovery',
  '* * * * *',
  'x-internal-secret',
  'internal_pipeline_secret',
  '{}'::jsonb
);

COMMIT;
