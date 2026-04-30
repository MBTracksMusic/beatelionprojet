/*
  # Replace public SECURITY DEFINER views with SECURITY INVOKER views

  Security Advisor lint 0010 warns on public views that run with the owner
  privileges. Several of these views intentionally expose sanitized public
  projections over private tables, so simply flipping them to security_invoker
  against the base tables would break public catalogue/profile pages.

  This migration preserves the existing view names, columns, and grants by:

  1. Capturing each flagged view definition.
  2. Creating a private SECURITY DEFINER function that returns the same rows.
  3. Replacing the public view with a SECURITY INVOKER view that selects from
     the private function.

  The public API still exposes only the same allowlisted view columns, while
  the privileged implementation no longer lives in a public SECURITY DEFINER
  view.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

CREATE TEMP TABLE _security_definer_view_targets (
  view_name text PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO _security_definer_view_targets (view_name)
VALUES
  ('battle_of_the_day'),
  ('elite_catalog_products'),
  ('forum_public_profiles_public'),
  ('leaderboard_producers'),
  ('producer_beats_ranked'),
  ('public_catalog_products'),
  ('public_home_battles_preview'),
  ('public_producer_profiles'),
  ('public_producer_profiles_v2'),
  ('public_visible_producer_profiles');

CREATE TEMP TABLE _security_definer_view_snapshots ON COMMIT DROP AS
SELECT
  c.oid AS view_oid,
  c.relname AS view_name,
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
JOIN _security_definer_view_targets t ON t.view_name = c.relname
WHERE n.nspname = 'public'
  AND c.relkind = 'v';

DO $$
DECLARE
  view_row record;
BEGIN
  FOR view_row IN
    SELECT *
    FROM _security_definer_view_snapshots
    ORDER BY view_name
  LOOP
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
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO service_role', view_row.private_function_signature);

    IF view_row.grant_anon THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO anon', view_row.private_function_signature);
    END IF;

    IF view_row.grant_authenticated THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s() TO authenticated', view_row.private_function_signature);
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

    RAISE NOTICE 'Replaced SECURITY DEFINER view % with SECURITY INVOKER wrapper over %',
      view_row.view_signature,
      view_row.private_function_signature;
  END LOOP;
END
$$;

COMMIT;
