/*
  # Step 3 - Attach tier limit helpers to INSERT RLS policies (safe)

  Scope:
  - Update only INSERT policy on public.products
  - Update only INSERT policy on public.battles
  - Keep existing is_producer_active checks and all current constraints
  - Add:
      - public.can_create_product(auth.uid())
      - public.can_create_battle(auth.uid())

  Out of scope:
  - No Stripe/webhook changes
  - No table changes
  - No SELECT/UPDATE/DELETE policy changes
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- products: INSERT policy
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Active producers can create products" ON public.products;

CREATE POLICY "Active producers can create products"
  ON public.products
  FOR INSERT
  TO authenticated
  WITH CHECK (
    producer_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND public.can_create_product(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- battles: INSERT policy (keeps latest pending_acceptance constraints)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Active producers can create battles" ON public.battles;

CREATE POLICY "Active producers can create battles"
  ON public.battles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    producer1_id = auth.uid()
    AND producer2_id IS NOT NULL
    AND producer1_id != producer2_id
    AND status = 'pending_acceptance'
    AND winner_id IS NULL
    AND votes_producer1 = 0
    AND votes_producer2 = 0
    AND accepted_at IS NULL
    AND rejected_at IS NULL
    AND admin_validated_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND public.can_create_battle(auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up2
      WHERE up2.id = producer2_id
        AND up2.is_producer_active = true
    )
    AND (
      product1_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM public.products p1
        WHERE p1.id = product1_id
          AND p1.producer_id = auth.uid()
          AND p1.deleted_at IS NULL
      )
    )
    AND (
      product2_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM public.products p2
        WHERE p2.id = product2_id
          AND p2.producer_id = producer2_id
          AND p2.deleted_at IS NULL
      )
    )
  );

COMMIT;
