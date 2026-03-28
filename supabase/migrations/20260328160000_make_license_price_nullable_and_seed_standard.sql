BEGIN;

ALTER TABLE public.licenses
  ALTER COLUMN price DROP NOT NULL;

INSERT INTO public.licenses (
  id,
  name,
  max_sales,
  max_streams,
  youtube_monetization,
  music_video_allowed,
  credit_required,
  exclusive_allowed,
  created_at,
  updated_at
)
SELECT
  gen_random_uuid(),
  'standard',
  NULL,
  NULL,
  true,
  true,
  false,
  false,
  now(),
  now()
WHERE NOT EXISTS (
  SELECT 1
  FROM public.licenses
  WHERE lower(name) = 'standard'
);

COMMIT;
