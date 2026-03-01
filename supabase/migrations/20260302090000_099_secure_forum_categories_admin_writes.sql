/*
  # Secure forum category management for admins only

  - Allows authenticated admins to create, update and delete forum categories.
  - Keeps public read access unchanged.
  - Does not modify topic/post/forum moderation logic.
*/

BEGIN;

GRANT INSERT, UPDATE, DELETE ON TABLE public.forum_categories TO authenticated;

DROP POLICY IF EXISTS "Authenticated admins can create forum categories" ON public.forum_categories;
CREATE POLICY "Authenticated admins can create forum categories"
  ON public.forum_categories
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Authenticated admins can update forum categories" ON public.forum_categories;
CREATE POLICY "Authenticated admins can update forum categories"
  ON public.forum_categories
  FOR UPDATE
  TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Authenticated admins can delete forum categories" ON public.forum_categories;
CREATE POLICY "Authenticated admins can delete forum categories"
  ON public.forum_categories
  FOR DELETE
  TO authenticated
  USING (public.is_admin(auth.uid()));

COMMIT;
