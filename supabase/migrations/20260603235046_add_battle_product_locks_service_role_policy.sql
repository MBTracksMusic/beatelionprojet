/*
  # Add explicit RLS policy for battle product locks

  battle_product_locks is an internal integrity table maintained by triggers.
  Client roles keep no table privileges; this policy makes the intended
  service_role-only access explicit and clears the RLS-enabled-with-no-policy
  advisor signal.
*/

BEGIN;

ALTER TABLE public.battle_product_locks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage battle product locks"
  ON public.battle_product_locks;

CREATE POLICY "Service role can manage battle product locks"
  ON public.battle_product_locks
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

REVOKE ALL ON TABLE public.battle_product_locks FROM PUBLIC;
REVOKE ALL ON TABLE public.battle_product_locks FROM anon;
REVOKE ALL ON TABLE public.battle_product_locks FROM authenticated;
GRANT ALL ON TABLE public.battle_product_locks TO service_role;

COMMIT;
