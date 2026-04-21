/*
  # Schedule audio processing worker

  ## Why
  Uploads now enqueue `audio_processing_jobs` correctly again, but the queue can
  stall if no external audio worker instance is actively polling.

  On staging, jobs remained stuck in `queued` with:
  - `attempts = 0`
  - `locked_at = NULL`
  - `processing_status = 'pending'`

  That indicates a missing consumer, not a broken enqueue path.

  ## Fix
  Reuse the existing internal cron helper to invoke the already deployed
  `process-audio-jobs` Edge Function every minute with the dedicated
  `AUDIO_WORKER_SECRET` header.

  This keeps processing server-side and does not expose any secret to the frontend.
*/

BEGIN;

SELECT public.schedule_internal_secret_worker_cron(
  'process-audio-jobs-every-minute',
  'process-audio-jobs',
  '* * * * *',
  'x-audio-worker-secret',
  'audio_worker_secret',
  '{"limit":3}'::jsonb
);

COMMIT;
