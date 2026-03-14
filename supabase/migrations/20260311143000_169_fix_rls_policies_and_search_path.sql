/*
  # Fix Supabase security advisor findings

  Findings addressed:
  1) RLS enabled with no policy
     - public.download_access_log
     - public.producer_plan_config
     - public.v_days

  2) Function search_path mutable
     - public.producer_tier_rank(public.producer_tier_type)

  Strategy:
  - Keep internal tables locked to client roles (anon/authenticated) with explicit deny-by-design policies.
  - Preserve backend/server access via service_role where required.
  - Set an explicit immutable search_path for producer_tier_rank.
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) public.download_access_log (internal anti-abuse audit table)
--    - no direct client access
--    - service_role keeps SELECT/INSERT for get-master-url edge function
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.download_access_log') IS NOT NULL THEN
    ALTER TABLE public.download_access_log ENABLE ROW LEVEL SECURITY;

    REVOKE ALL ON TABLE public.download_access_log FROM PUBLIC;
    REVOKE ALL ON TABLE public.download_access_log FROM anon;
    REVOKE ALL ON TABLE public.download_access_log FROM authenticated;

    GRANT SELECT, INSERT ON TABLE public.download_access_log TO service_role;

    DROP POLICY IF EXISTS "download_access_log_no_client_access" ON public.download_access_log;
    CREATE POLICY "download_access_log_no_client_access"
      ON public.download_access_log
      FOR ALL
      TO anon, authenticated
      USING (false)
      WITH CHECK (false);
  ELSE
    RAISE NOTICE 'Table public.download_access_log not found; skipped hardening.';
  END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 2) public.producer_plan_config (deprecated legacy config table)
--    - no direct client access
--    - kept for backward SQL compatibility only
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.producer_plan_config') IS NOT NULL THEN
    ALTER TABLE public.producer_plan_config ENABLE ROW LEVEL SECURITY;

    REVOKE ALL ON TABLE public.producer_plan_config FROM PUBLIC;
    REVOKE ALL ON TABLE public.producer_plan_config FROM anon;
    REVOKE ALL ON TABLE public.producer_plan_config FROM authenticated;

    DROP POLICY IF EXISTS "producer_plan_config_no_client_access" ON public.producer_plan_config;
    CREATE POLICY "producer_plan_config_no_client_access"
      ON public.producer_plan_config
      FOR ALL
      TO anon, authenticated
      USING (false)
      WITH CHECK (false);
  ELSE
    RAISE NOTICE 'Table public.producer_plan_config not found; skipped hardening.';
  END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 3) public.v_days (utility relation, if present as a TABLE)
--    - lock client access explicitly
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_relkind "char";
BEGIN
  SELECT c.relkind
  INTO v_relkind
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'v_days'
  LIMIT 1;

  IF v_relkind IS NULL THEN
    RAISE NOTICE 'Relation public.v_days not found; skipped hardening.';
  ELSIF v_relkind IN ('r', 'p') THEN
    ALTER TABLE public.v_days ENABLE ROW LEVEL SECURITY;

    REVOKE ALL ON TABLE public.v_days FROM PUBLIC;
    REVOKE ALL ON TABLE public.v_days FROM anon;
    REVOKE ALL ON TABLE public.v_days FROM authenticated;

    DROP POLICY IF EXISTS "v_days_no_client_access" ON public.v_days;
    CREATE POLICY "v_days_no_client_access"
      ON public.v_days
      FOR ALL
      TO anon, authenticated
      USING (false)
      WITH CHECK (false);
  ELSE
    RAISE NOTICE 'Relation public.v_days exists but is not a table (relkind=%); skipped hardening.', v_relkind;
  END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 4) Fix mutable search_path on producer_tier_rank
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('public.producer_tier_rank(public.producer_tier_type)') IS NOT NULL THEN
    EXECUTE
      'ALTER FUNCTION public.producer_tier_rank(public.producer_tier_type) SET search_path = pg_catalog';
  ELSE
    RAISE NOTICE 'Function public.producer_tier_rank(public.producer_tier_type) not found; skipped.';
  END IF;
END
$$;

COMMIT;
