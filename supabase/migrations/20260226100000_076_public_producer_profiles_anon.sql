/*
  # Allow public read access to producer public profiles

  - Adds a dedicated SELECT policy for anon + authenticated roles.
  - Restricts visibility to active producer profiles only.
*/

BEGIN;

DROP POLICY IF EXISTS "Public can view producer public profile" ON public.user_profiles;

CREATE POLICY "Public can view producer public profile"
  ON public.user_profiles
  FOR SELECT
  TO anon, authenticated
  USING (is_producer_active = true);

COMMIT;
