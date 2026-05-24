/*
  # 264 — Email pipeline kill-switch + per-hour quota
  See supabase/migrations/20260524184000_264_email_pipeline_kill_switch_and_quota.sql
*/

BEGIN;

INSERT INTO public.app_settings (key, value)
VALUES (
  'email_pipeline_settings',
  jsonb_build_object(
    'enabled',       true,
    'max_per_hour',  200,
    'max_per_batch', 50
  )
)
ON CONFLICT (key) DO NOTHING;

COMMIT;
