/*
  # Fix battles INSERT policy invited producer lookup

  Problem:
  - `public.battles` INSERT policy checked the invited producer directly against
    `public.user_profiles`.
  - Since `public.user_profiles` is owner-only under RLS, authenticated users
    can no longer read another producer row during the policy evaluation.
  - This causes false `42501 new row violates row-level security policy`
    errors even when quota and form inputs are valid.

  Fix:
  - Keep the current quota and product ownership guards.
  - Replace the invited producer activity check with the public allowlisted
    view `public.public_producer_profiles`, which only exposes active producers.
*/

BEGIN;

DROP POLICY IF EXISTS "Active producers can create battles" ON public.battles;

CREATE POLICY "Active producers can create battles"
  ON public.battles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND producer1_id = auth.uid()
    AND producer2_id IS NOT NULL
    AND producer1_id != producer2_id
    AND status = 'pending_acceptance'
    AND winner_id IS NULL
    AND votes_producer1 = 0
    AND votes_producer2 = 0
    AND accepted_at IS NULL
    AND rejected_at IS NULL
    AND admin_validated_at IS NULL
    AND public.can_create_battle(auth.uid()) = true
    AND EXISTS (
      SELECT 1
      FROM public.public_producer_profiles pp2
      WHERE pp2.user_id = producer2_id
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
