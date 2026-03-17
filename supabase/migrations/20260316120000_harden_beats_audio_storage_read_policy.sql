/*
  # Harden beats-audio read access (production emergency)

  Why:
  - Prevent any anonymous or broad authenticated read/list access on beats-audio.
  - Keep beats-audio private and readable only by the owning producer.
*/

BEGIN;

UPDATE storage.buckets
SET public = false
WHERE id = 'beats-audio';

DO $$
DECLARE
  policy_row record;
BEGIN
  -- Remove every SELECT policy that references beats-audio to avoid OR-based policy bypass.
  FOR policy_row IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND upper(cmd) = 'SELECT'
      AND (
        coalesce(qual, '') ILIKE '%beats-audio%'
        OR coalesce(with_check, '') ILIKE '%beats-audio%'
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', policy_row.policyname);
  END LOOP;

  -- Recreate a single strict read policy.
  DROP POLICY IF EXISTS "Beats audio owner-only read" ON storage.objects;
  CREATE POLICY "Beats audio owner-only read"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'beats-audio'
      AND auth.uid() IS NOT NULL
      AND owner = auth.uid()
      AND public.is_active_producer(auth.uid())
    );
END
$$;

COMMIT;
