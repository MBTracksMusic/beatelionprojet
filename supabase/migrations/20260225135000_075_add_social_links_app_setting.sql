/*
  # Seed social_links in app_settings

  - Uses existing public.app_settings as the single settings registry.
  - Ensures `social_links` key exists with scalable JSON shape.
*/

BEGIN;

INSERT INTO public.app_settings (key, value)
VALUES (
  'social_links',
  '{"twitter":"","instagram":"","youtube":""}'::jsonb
)
ON CONFLICT (key) DO UPDATE
SET
  value = CASE
    WHEN jsonb_typeof(public.app_settings.value) = 'object'
      THEN '{"twitter":"","instagram":"","youtube":""}'::jsonb || public.app_settings.value
    ELSE '{"twitter":"","instagram":"","youtube":""}'::jsonb
  END,
  updated_at = now();

COMMIT;
