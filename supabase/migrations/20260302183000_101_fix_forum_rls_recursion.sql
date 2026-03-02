/*
  # Fix forum RLS recursion on forum_topics SELECT

  Problem:
  - migration 100 introduced a circular dependency between SELECT policies:
    forum_topics -> forum_posts -> forum_topics
  - PostgreSQL raises 42P17 "infinite recursion detected in policy"

  Fix:
  - replace forum_topics SELECT policy with a version that never references
    forum_posts
  - keep category access enforcement and deleted-topic filtering
  - preserve owner/admin visibility for non-public topics without reintroducing
    recursion
*/

BEGIN;

DROP POLICY IF EXISTS "Forum topics readable" ON public.forum_topics;

CREATE POLICY "Forum topics readable"
  ON public.forum_topics
  FOR SELECT
  TO anon, authenticated
  USING (
    public.forum_can_access_category(category_id, auth.uid())
    AND (
      COALESCE(is_deleted, false) = false
      OR user_id = auth.uid()
      OR public.is_admin(auth.uid())
    )
  );

COMMIT;
