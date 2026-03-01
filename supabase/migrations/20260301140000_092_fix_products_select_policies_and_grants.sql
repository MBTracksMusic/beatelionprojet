/*
  # Fix products SELECT access for producer dashboard

  - Keeps RLS enabled on public.products.
  - Restores explicit SELECT grants for newly added safe columns.
  - Recreates strict SELECT policies for public, producer, and buyers.
  - Keeps direct DELETE disabled from the client to force RPC usage.
*/

BEGIN;

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- The frontend now requests these columns in PRODUCT_SAFE_COLUMNS.
GRANT SELECT (status, version, original_beat_id, watermarked_bucket)
  ON TABLE public.products TO PUBLIC;
GRANT SELECT (status, version, original_beat_id, watermarked_bucket)
  ON TABLE public.products TO anon;
GRANT SELECT (status, version, original_beat_id, watermarked_bucket)
  ON TABLE public.products TO authenticated;

DROP POLICY IF EXISTS "Anyone can view published products" ON public.products;
DROP POLICY IF EXISTS "Public can view active products" ON public.products;
CREATE POLICY "Public can view active products"
  ON public.products
  FOR SELECT
  USING (
    deleted_at IS NULL
    AND status = 'active'
    AND is_published = true
    AND (is_exclusive = false OR (is_exclusive = true AND is_sold = false))
  );

DROP POLICY IF EXISTS "Producers can view own products" ON public.products;
DROP POLICY IF EXISTS "Producer can view own products" ON public.products;
CREATE POLICY "Producer can view own products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() = producer_id
    AND deleted_at IS NULL
  );

DROP POLICY IF EXISTS "Buyers can view purchased products" ON public.products;
CREATE POLICY "Buyers can view purchased products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.user_id = auth.uid()
        AND pu.status IN ('completed', 'refunded')
    )
  );

DROP POLICY IF EXISTS "Producers can delete own unsold products" ON public.products;
DROP POLICY IF EXISTS "Producer can delete own products" ON public.products;

COMMIT;
