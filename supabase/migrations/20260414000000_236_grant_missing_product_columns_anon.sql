/*
  # Fix: GRANT missing product columns to anon / authenticated

  ## Root cause
  Migration 086 (secure_master_access_and_storage_split) set up column-level SELECT
  grants for anon and authenticated on public.products using a whitelist snapshot.
  Subsequent migrations added new columns WITHOUT extending the grants:

  | Column            | Added by migration                           |
  |-------------------|----------------------------------------------|
  | version_number    | 20260301143000_093_product_versioning        |
  | parent_product_id | 20260301143000_093_product_versioning        |
  | archived_at       | 20260301143000_093_product_versioning        |
  | early_access_until| 20260322234500_add_product_early_access      |

  When migration 235 converted public_catalog_products and public_products to
  security_invoker = true, queries from anon/authenticated callers started failing
  with "permission denied for column X of relation products".

  ## Fix
  Grant SELECT on the missing columns to anon, authenticated, and PUBLIC.
  None of these columns are sensitive (UUIDs, timestamps, integer version counters).
*/

BEGIN;

GRANT SELECT (
  version_number,
  parent_product_id,
  archived_at,
  early_access_until
) ON TABLE public.products TO PUBLIC;

GRANT SELECT (
  version_number,
  parent_product_id,
  archived_at,
  early_access_until
) ON TABLE public.products TO anon;

GRANT SELECT (
  version_number,
  parent_product_id,
  archived_at,
  early_access_until
) ON TABLE public.products TO authenticated;

COMMIT;
