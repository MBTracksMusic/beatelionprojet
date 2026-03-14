/*
  # Enforce private contracts bucket

  License contract PDFs are sensitive files and must never be exposed through a public bucket.
  This migration force-enables private visibility for the `contracts` storage bucket.
*/

BEGIN;

UPDATE storage.buckets
SET public = false
WHERE id = 'contracts';

COMMIT;
