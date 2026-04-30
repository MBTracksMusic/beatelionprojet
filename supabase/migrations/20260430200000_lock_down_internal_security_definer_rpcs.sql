/*
  # Lock down internal SECURITY DEFINER RPC entrypoints

  This is a narrow follow-up to 20260429000000_harden_security_definer_permissions.sql.
  That migration made grants explicit, but it also re-exposed a few internal,
  legacy, or scheduler-only SECURITY DEFINER functions to the authenticated
  PostgREST role.

  This migration only changes EXECUTE privileges. It does not alter function
  bodies, tables, policies, views, or data.

  Keep authenticated access on:
  - RPCs called directly by the current frontend.
  - Functions referenced directly by RLS policies.
  - Intentional public/read projection functions handled by later migrations.

  Revoke authenticated access on:
  - internal helpers called by other SECURITY DEFINER functions.
  - scheduler/maintenance functions that should be service_role only.
  - the legacy unguarded campaign producer listing RPC that exposes emails.
*/

BEGIN;

CREATE TEMP TABLE _internal_security_definer_rpcs (
  function_name text PRIMARY KEY,
  reason text NOT NULL
) ON COMMIT DROP;

INSERT INTO _internal_security_definer_rpcs (function_name, reason)
VALUES
  ('admin_list_campaign_producers', 'legacy unguarded admin listing; exposes user emails'),
  ('check_rpc_rate_limit', 'internal rate-limit helper called from guarded RPCs and Edge Functions'),
  ('cleanup_rpc_rate_limit_counters', 'maintenance cleanup; service role only'),
  ('detect_admin_action_anomalies', 'monitoring/alert helper; service role only'),
  ('finalize_expired_battles', 'called through the guarded agent_finalize_expired_battles wrapper'),
  ('hash_request_value', 'internal hashing helper used by fraud logging'),
  ('log_fraud_event', 'internal audit helper called by vote/comment/forum RPCs'),
  ('recalculate_engagement', 'internal scoring helper called after battle state changes'),
  ('reset_elo_for_new_season', 'season rotation helper called by create_new_season/check_and_rotate_season');

DO $$
DECLARE
  fn record;
BEGIN
  FOR fn IN
    SELECT
      format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS signature,
      r.reason
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN _internal_security_definer_rpcs r ON r.function_name = p.proname
    WHERE n.nspname = 'public'
      AND p.prosecdef = true
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', fn.signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', fn.signature);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', fn.signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', fn.signature);

    RAISE NOTICE 'Locked down %: %', fn.signature, fn.reason;
  END LOOP;
END
$$;

COMMIT;
