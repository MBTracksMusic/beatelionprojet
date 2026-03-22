/*
  # Fix public catalog view permissions for anon/authenticated users
*/

BEGIN;

ALTER VIEW IF EXISTS public.public_catalog_products
  SET (security_invoker = false);

COMMENT ON VIEW public.public_catalog_products
IS 'Public-safe catalog read model enriched with producer ranking and premium early access filtering.';

REVOKE ALL ON TABLE public.public_catalog_products FROM PUBLIC;
REVOKE ALL ON TABLE public.public_catalog_products FROM anon;
REVOKE ALL ON TABLE public.public_catalog_products FROM authenticated;
GRANT SELECT ON TABLE public.public_catalog_products TO anon;
GRANT SELECT ON TABLE public.public_catalog_products TO authenticated;
GRANT SELECT ON TABLE public.public_catalog_products TO service_role;

COMMIT;
