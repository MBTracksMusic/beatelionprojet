/*
  # Harden distributed rate limit RPC against concurrency races

  - Keeps the same public.check_rate_limit(p_key text, p_limit int) signature
  - Replaces read-then-write logic with a single atomic upsert
  - Preserves the 60-second reset window and SECURITY DEFINER behavior
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.check_rate_limit(p_key text, p_limit int)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_count int;
BEGIN
  INSERT INTO public.rate_limits(key, count, updated_at)
  VALUES (p_key, 1, now())
  ON CONFLICT (key)
  DO UPDATE SET
    count = CASE
      WHEN now() - public.rate_limits.updated_at > interval '60 seconds'
        THEN 1
      ELSE public.rate_limits.count + 1
    END,
    updated_at = now()
  RETURNING count INTO current_count;

  RETURN current_count <= p_limit;
END;
$$;

COMMIT;
