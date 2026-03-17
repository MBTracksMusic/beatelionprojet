/*
  # Remove direct buyer read policy on contracts storage

  Security goal:
  - Force all contract file access through hardened get-contract-url edge function.
  - Remove direct storage.objects SELECT path for authenticated buyers.
  - Keep contracts bucket private.
*/

BEGIN;

UPDATE storage.buckets
SET public = false
WHERE id = 'contracts';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'storage'
      AND table_name = 'objects'
  ) THEN
    DROP POLICY IF EXISTS "Buyers can read own contracts" ON storage.objects;
  END IF;
END
$$;

COMMIT;
