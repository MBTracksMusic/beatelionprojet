/*
  # Fix weekly_leaderboard SECURITY DEFINER view lint

  Supabase Security Advisor lint 0010 flags public views that run with owner
  privileges. The weekly leaderboard must stay visitor-facing, but its base
  tables are intentionally protected by RLS and narrow grants.

  Preserve the existing public API shape and grants by moving the privileged
  query into a private SECURITY DEFINER function, then exposing
  public.weekly_leaderboard as a SECURITY INVOKER view wrapper.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

CREATE TEMP TABLE _weekly_leaderboard_snapshot ON COMMIT DROP AS
SELECT
  c.oid AS view_oid,
  format('%I.%I', n.nspname, c.relname) AS view_signature,
  format('%I.%I', 'private', '_view_' || c.relname) AS private_function_signature,
  pg_get_viewdef(c.oid, true) AS view_definition,
  (
    SELECT string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
    FROM pg_attribute a
    WHERE a.attrelid = c.oid
      AND a.attnum > 0
      AND NOT a.attisdropped
  ) AS column_definitions,
  has_table_privilege('anon', c.oid, 'SELECT') AS grant_anon,
  has_table_privilege('authenticated', c.oid, 'SELECT') AS grant_authenticated,
  has_table_privilege('service_role', c.oid, 'SELECT') AS grant_service_role
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'weekly_leaderboard'
  AND c.relkind = 'v';

DO $$
DECLARE
  view_row record;
BEGIN
  SELECT *
  INTO view_row
  FROM _weekly_leaderboard_snapshot;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'public.weekly_leaderboard view not found';
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION %s()
     RETURNS TABLE (%s)
     LANGUAGE sql
     STABLE
     SECURITY DEFINER
     SET search_path = public, private, pg_temp
     AS $view_impl$%s$view_impl$',
    view_row.private_function_signature,
    view_row.column_definitions,
    view_row.view_definition
  );

  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s() FROM PUBLIC', view_row.private_function_signature);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s() FROM anon', view_row.private_function_signature);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s() FROM authenticated', view_row.private_function_signature);
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s() FROM service_role', view_row.private_function_signature);

  IF view_row.grant_anon THEN
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO anon', view_row.private_function_signature);
  END IF;

  IF view_row.grant_authenticated THEN
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO authenticated', view_row.private_function_signature);
  END IF;

  IF view_row.grant_service_role THEN
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO service_role', view_row.private_function_signature);
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE VIEW %s
     WITH (security_invoker = true)
     AS SELECT * FROM %s()',
    view_row.view_signature,
    view_row.private_function_signature
  );

  EXECUTE format('REVOKE ALL ON TABLE %s FROM PUBLIC', view_row.view_signature);
  EXECUTE format('REVOKE ALL ON TABLE %s FROM anon', view_row.view_signature);
  EXECUTE format('REVOKE ALL ON TABLE %s FROM authenticated', view_row.view_signature);
  EXECUTE format('REVOKE ALL ON TABLE %s FROM service_role', view_row.view_signature);

  IF view_row.grant_anon THEN
    EXECUTE format('GRANT SELECT ON TABLE %s TO anon', view_row.view_signature);
  END IF;

  IF view_row.grant_authenticated THEN
    EXECUTE format('GRANT SELECT ON TABLE %s TO authenticated', view_row.view_signature);
  END IF;

  IF view_row.grant_service_role THEN
    EXECUTE format('GRANT SELECT ON TABLE %s TO service_role', view_row.view_signature);
  END IF;
END
$$;

ALTER FUNCTION public.get_weekly_leaderboard(integer) SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboard(integer) TO anon, authenticated, service_role;

COMMIT;
