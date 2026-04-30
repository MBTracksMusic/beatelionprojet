/*
  # Move authenticated SECURITY DEFINER RPCs out of the exposed API schema

  Supabase Security Advisor lint 0029 warns when signed-in users can execute a
  SECURITY DEFINER function through PostgREST at /rest/v1/rpc/<function>.

  Many of these RPCs are intentional business entrypoints: admin actions,
  producer workflows, purchase flows, account deletion, quota checks, and RLS
  helpers. Revoking them outright would break the app. Instead, this migration:

  1. Captures every remaining non-trigger public SECURITY DEFINER function
     executable by authenticated.
  2. Moves the privileged implementation to private.<function>.
  3. Recreates public.<function> as a SECURITY INVOKER wrapper with the same
     signature, return type, volatility, and execute grants.
  4. Locks down SECURITY DEFINER trigger functions separately because trigger
     functions cannot be recreated as SQL RPC wrappers and should not be
     executable directly by API roles.

  The REST API keeps the same RPC names, but no signed-in user directly
  executes a SECURITY DEFINER function in the exposed public schema anymore.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

CREATE TEMP TABLE _security_definer_rpc_wrap_targets ON COMMIT DROP AS
SELECT
  p.oid,
  p.proname,
  p.pronargs,
  p.proretset,
  CASE p.provolatile
    WHEN 'i' THEN 'IMMUTABLE'
    WHEN 's' THEN 'STABLE'
    ELSE 'VOLATILE'
  END AS volatility,
  format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS public_signature,
  format('%I.%I(%s)', 'private', p.proname, pg_get_function_identity_arguments(p.oid)) AS private_signature,
  pg_get_function_arguments(p.oid) AS create_arguments,
  pg_get_function_result(p.oid) AS result_type,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS grant_anon,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS grant_authenticated,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS grant_service_role,
  (
    SELECT COALESCE(string_agg(format('$%s', i), ', ' ORDER BY i), '')
    FROM generate_series(1, p.pronargs) AS args(i)
  ) AS call_arguments
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prosecdef = true
  AND p.prorettype <> 'trigger'::regtype
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE');

CREATE TEMP TABLE _security_definer_trigger_lockdown_targets ON COMMIT DROP AS
SELECT
  p.oid,
  format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS public_signature,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS grant_service_role
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prosecdef = true
  AND p.prorettype = 'trigger'::regtype
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE');

DO $$
DECLARE
  fn record;
  wrapper_sql text;
  wrapper_body text;
BEGIN
  FOR fn IN
    SELECT *
    FROM _security_definer_rpc_wrap_targets
    ORDER BY proname, public_signature
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET SCHEMA private', fn.public_signature);

    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.private_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', fn.private_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', fn.private_signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.private_signature);

    IF fn.grant_anon THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', fn.private_signature);
    END IF;

    IF fn.grant_authenticated THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn.private_signature);
    END IF;

    IF lower(fn.result_type) = 'void' THEN
      wrapper_body := format(
        'BEGIN PERFORM private.%I(%s); END;',
        fn.proname,
        fn.call_arguments
      );

      wrapper_sql := format(
        'CREATE FUNCTION public.%I(%s)
         RETURNS %s
         LANGUAGE plpgsql
         %s
         SECURITY INVOKER
         SET search_path = public, private, pg_temp
         AS $rpc_wrapper$%s$rpc_wrapper$',
        fn.proname,
        fn.create_arguments,
        fn.result_type,
        fn.volatility,
        wrapper_body
      );
    ELSIF fn.proretset THEN
      wrapper_body := format(
        'SELECT * FROM private.%I(%s);',
        fn.proname,
        fn.call_arguments
      );

      wrapper_sql := format(
        'CREATE FUNCTION public.%I(%s)
         RETURNS %s
         LANGUAGE sql
         %s
         SECURITY INVOKER
         SET search_path = public, private, pg_temp
         AS $rpc_wrapper$%s$rpc_wrapper$',
        fn.proname,
        fn.create_arguments,
        fn.result_type,
        fn.volatility,
        wrapper_body
      );
    ELSE
      wrapper_body := format(
        'SELECT private.%I(%s);',
        fn.proname,
        fn.call_arguments
      );

      wrapper_sql := format(
        'CREATE FUNCTION public.%I(%s)
         RETURNS %s
         LANGUAGE sql
         %s
         SECURITY INVOKER
         SET search_path = public, private, pg_temp
         AS $rpc_wrapper$%s$rpc_wrapper$',
        fn.proname,
        fn.create_arguments,
        fn.result_type,
        fn.volatility,
        wrapper_body
      );
    END IF;

    EXECUTE wrapper_sql;

    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.public_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', fn.public_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', fn.public_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM service_role', fn.public_signature);

    IF fn.grant_anon THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', fn.public_signature);
    END IF;

    IF fn.grant_authenticated THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn.public_signature);
    END IF;

    IF fn.grant_service_role THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.public_signature);
    END IF;

    RAISE NOTICE 'Moved SECURITY DEFINER implementation to %, recreated invoker wrapper %',
      fn.private_signature,
      fn.public_signature;
  END LOOP;
END
$$;

DO $$
DECLARE
  fn record;
BEGIN
  FOR fn IN
    SELECT *
    FROM _security_definer_trigger_lockdown_targets
    ORDER BY public_signature
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.public_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', fn.public_signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', fn.public_signature);

    IF fn.grant_service_role THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.public_signature);
    END IF;

    RAISE NOTICE 'Revoked direct API-role EXECUTE on SECURITY DEFINER trigger function %',
      fn.public_signature;
  END LOOP;
END
$$;

COMMIT;
