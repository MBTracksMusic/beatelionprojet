/*
  # Drop unused authenticated forum profile projection

  Goal:
  - remove an unused object that exposes more profile data than the forum UI needs
  - keep forum_public_profiles_public as the only forum author projection in use
*/

BEGIN;

DROP VIEW IF EXISTS public.forum_public_profiles;
DROP FUNCTION IF EXISTS public.get_forum_public_profiles();

COMMIT;
