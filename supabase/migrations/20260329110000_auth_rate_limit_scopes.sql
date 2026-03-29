BEGIN;

ALTER TABLE public.contact_submit_rate_limit
  ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'contact_submit';

COMMENT ON COLUMN public.contact_submit_rate_limit.scope IS
  'Logical rate-limit bucket. Allows auth flows to avoid sharing the same IP quota as contact-submit.';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.contact_submit_rate_limit'::regclass
      AND conname = 'contact_submit_rate_limit_pkey'
  ) THEN
    ALTER TABLE public.contact_submit_rate_limit
      DROP CONSTRAINT contact_submit_rate_limit_pkey;
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.contact_submit_rate_limit'::regclass
      AND conname = 'contact_submit_rate_limit_pkey'
  ) THEN
    ALTER TABLE public.contact_submit_rate_limit
      ADD CONSTRAINT contact_submit_rate_limit_pkey
      PRIMARY KEY (ip_hash, scope, window_start);
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_contact_submit_rate_limit_scope_window_start
  ON public.contact_submit_rate_limit (scope, window_start DESC);

DROP FUNCTION IF EXISTS public.rpc_contact_submit_rate_limit(text);

CREATE OR REPLACE FUNCTION public.rpc_contact_submit_rate_limit(
  p_ip_hash text,
  p_scope text DEFAULT 'contact_submit'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ip_hash text := btrim(COALESCE(p_ip_hash, ''));
  v_scope text := lower(btrim(COALESCE(p_scope, 'contact_submit')));
  v_window_start timestamptz;
  v_counter integer := 0;
BEGIN
  IF v_ip_hash = '' THEN
    RAISE EXCEPTION 'invalid_ip_hash';
  END IF;

  IF v_scope = '' THEN
    RAISE EXCEPTION 'invalid_rate_limit_scope';
  END IF;

  v_window_start := date_trunc('hour', now())
    + floor(extract(minute from now()) / 10)::int * interval '10 minutes';

  INSERT INTO public.contact_submit_rate_limit (
    ip_hash,
    scope,
    window_start,
    counter,
    updated_at
  )
  VALUES (
    v_ip_hash,
    v_scope,
    v_window_start,
    1,
    now()
  )
  ON CONFLICT (ip_hash, scope, window_start)
  DO UPDATE
    SET counter = public.contact_submit_rate_limit.counter + 1,
        updated_at = now()
  RETURNING counter INTO v_counter;

  IF v_counter > 5 THEN
    RAISE EXCEPTION 'rate_limit_exceeded';
  END IF;

  DELETE FROM public.contact_submit_rate_limit
  WHERE window_start < now() - interval '2 days';

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rpc_contact_submit_rate_limit(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_contact_submit_rate_limit(text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_contact_submit_rate_limit(text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_contact_submit_rate_limit(text, text) TO service_role;

COMMIT;
