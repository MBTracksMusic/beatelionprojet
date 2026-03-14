/*
  # Allow pipeline workers to emit monitoring alerts

  Why:
  - Internal Edge workers now emit alert events through public.log_monitoring_alert.
  - service_role must be allowed to execute this helper.
*/

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'log_monitoring_alert'
      AND pg_get_function_identity_arguments(p.oid) = 'text, text, text, text, uuid, jsonb'
  ) THEN
    GRANT EXECUTE ON FUNCTION public.log_monitoring_alert(text, text, text, text, uuid, jsonb) TO service_role;
  END IF;
END
$$;

COMMIT;
