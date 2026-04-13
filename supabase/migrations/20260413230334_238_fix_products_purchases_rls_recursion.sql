/*
  # Fix: infinite recursion in products / purchases RLS policies

  ## Root cause
  Migration 235 added this policy on public.purchases:

      CREATE POLICY "Producers can view purchases of their products"
        ON public.purchases FOR SELECT TO authenticated
        USING (EXISTS (SELECT 1 FROM public.products pr
                       WHERE pr.id = purchases.product_id
                         AND pr.producer_id = auth.uid()));

  A pre-existing policy on public.products ("Authenticated users can view products")
  already contained:

      EXISTS (SELECT 1 FROM public.purchases pur
              WHERE pur.user_id = auth.uid() AND pur.product_id = products.id)

  Accessing products triggers the products policy → which checks purchases →
  which triggers the purchases policy → which checks products → infinite loop.

  Postgres error: "infinite recursion detected in policy for relation 'products'"
  This caused HTTP 500 on every query that joined products for authenticated users
  (battles + embedded products, cart_items + embedded products, etc.).

  ## Fix
  The purchases table already has a denormalized producer_id column populated at
  purchase time. Use it directly — no join to products needed.
*/

BEGIN;

DROP POLICY IF EXISTS "Producers can view purchases of their products" ON public.purchases;

CREATE POLICY "Producers can view purchases of their products"
  ON public.purchases
  FOR SELECT
  TO authenticated
  USING (producer_id = auth.uid());

COMMIT;
