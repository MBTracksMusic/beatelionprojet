/*
  # Fix elite_waitlist anon insert policy

  Why:
  - On this project, anon requests may not satisfy `auth.uid() IS NULL`.
  - Keep insert open for anon only when `user_id IS NULL`.
*/

BEGIN;

DROP POLICY IF EXISTS "Anonymous can insert elite waitlist" ON public.elite_waitlist;
CREATE POLICY "Anonymous can insert elite waitlist"
  ON public.elite_waitlist
  FOR INSERT
  TO anon
  WITH CHECK (
    user_id IS NULL
    AND length(btrim(email)) > 0
  );

COMMIT;
