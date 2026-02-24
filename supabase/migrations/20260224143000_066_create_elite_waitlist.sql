/*
  # Create elite_waitlist table

  Scope:
  - Add public.elite_waitlist to collect interest for ELITE plan
  - Keep strict RLS (insert only, no public select)
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.elite_waitlist (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  user_id uuid NULL REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS elite_waitlist_email_key
  ON public.elite_waitlist (email);

CREATE INDEX IF NOT EXISTS idx_elite_waitlist_created_at_desc
  ON public.elite_waitlist (created_at DESC);

ALTER TABLE public.elite_waitlist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated can insert elite waitlist" ON public.elite_waitlist;
CREATE POLICY "Authenticated can insert elite waitlist"
  ON public.elite_waitlist
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND user_id = auth.uid()
    AND length(btrim(email)) > 0
  );

DROP POLICY IF EXISTS "Anonymous can insert elite waitlist" ON public.elite_waitlist;
CREATE POLICY "Anonymous can insert elite waitlist"
  ON public.elite_waitlist
  FOR INSERT
  TO anon
  WITH CHECK (
    auth.uid() IS NULL
    AND user_id IS NULL
    AND length(btrim(email)) > 0
  );

COMMIT;
