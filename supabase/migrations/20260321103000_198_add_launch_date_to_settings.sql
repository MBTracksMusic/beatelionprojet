/*
  # Add optional launch date to public.settings

  - Extends the singleton maintenance settings with an optional `launch_date`.
  - `launch_date IS NULL` keeps the existing simple maintenance mode.
  - `launch_date IS NOT NULL` enables the launch countdown display on the frontend.
*/

BEGIN;

ALTER TABLE public.settings
ADD COLUMN IF NOT EXISTS launch_date timestamptz NULL;

COMMENT ON COLUMN public.settings.launch_date IS
  'Optional launch datetime shown on the maintenance screen. NULL keeps the simple maintenance mode.';

COMMIT;
