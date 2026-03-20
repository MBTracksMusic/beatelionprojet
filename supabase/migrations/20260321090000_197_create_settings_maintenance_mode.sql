/*
  # Create public.settings singleton for dynamic maintenance mode

  - Adds a singleton settings table with a `maintenance_mode` boolean.
  - Seeds exactly one default row with `maintenance_mode = false`.
  - Allows public read access for frontend bootstrapping.
  - Restricts writes to admins only through RLS.
  - Publishes the table to Supabase Realtime for live updates.
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  maintenance_mode boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

COMMENT ON TABLE public.settings IS 'Singleton public settings used for global frontend controls such as maintenance mode.';
COMMENT ON COLUMN public.settings.maintenance_mode IS 'When true, the public site enters maintenance mode.';

CREATE UNIQUE INDEX IF NOT EXISTS settings_singleton_idx
  ON public.settings ((true));

CREATE OR REPLACE FUNCTION public.touch_settings_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := timezone('utc', now());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS settings_touch_updated_at ON public.settings;
CREATE TRIGGER settings_touch_updated_at
BEFORE UPDATE ON public.settings
FOR EACH ROW
EXECUTE FUNCTION public.touch_settings_updated_at();

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read settings" ON public.settings;
CREATE POLICY "Anyone can read settings"
ON public.settings
FOR SELECT
TO anon, authenticated
USING (true);

DROP POLICY IF EXISTS "Admins can insert settings" ON public.settings;
CREATE POLICY "Admins can insert settings"
ON public.settings
FOR INSERT
TO authenticated
WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can update settings" ON public.settings;
CREATE POLICY "Admins can update settings"
ON public.settings
FOR UPDATE
TO authenticated
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

GRANT SELECT ON TABLE public.settings TO anon;
GRANT SELECT ON TABLE public.settings TO authenticated;
GRANT SELECT ON TABLE public.settings TO service_role;
GRANT INSERT, UPDATE ON TABLE public.settings TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.settings TO service_role;

INSERT INTO public.settings (maintenance_mode)
VALUES (false)
ON CONFLICT ((true)) DO NOTHING;

ALTER PUBLICATION supabase_realtime ADD TABLE public.settings;

COMMIT;
