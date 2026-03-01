/*
  # Create isolated forum module

  - Creates forum_categories, forum_topics, forum_posts, forum_likes
  - Adds strict RLS with public read and authenticated writes
  - Keeps owner/admin moderation rules isolated from existing business logic
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.forum_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (btrim(name) <> ''),
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_topics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (btrim(title) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (btrim(content) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT forum_likes_post_user_key UNIQUE (post_id, user_id)
);

ALTER TABLE public.forum_categories
  ADD COLUMN IF NOT EXISTS slug text,
  ADD COLUMN IF NOT EXISTS is_premium_only boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 0;

ALTER TABLE public.forum_topics
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS slug text,
  ADD COLUMN IF NOT EXISTS is_pinned boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_locked boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_post_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS post_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.forum_posts
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_forum_topics_category_updated_desc
  ON public.forum_topics (category_id, updated_at DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_topics_category_last_post_desc
  ON public.forum_topics (category_id, last_post_at DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_created_asc
  ON public.forum_posts (topic_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_forum_likes_post_created_desc
  ON public.forum_likes (post_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.forum_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS forum_topics_touch_updated_at ON public.forum_topics;
CREATE TRIGGER forum_topics_touch_updated_at
  BEFORE UPDATE ON public.forum_topics
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_touch_updated_at();

DROP TRIGGER IF EXISTS forum_posts_touch_updated_at ON public.forum_posts;
CREATE TRIGGER forum_posts_touch_updated_at
  BEFORE UPDATE ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.forum_touch_updated_at();

ALTER TABLE public.forum_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_likes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.forum_categories FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_topics FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_posts FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_likes FROM PUBLIC;

REVOKE ALL ON TABLE public.forum_categories FROM anon;
REVOKE ALL ON TABLE public.forum_topics FROM anon;
REVOKE ALL ON TABLE public.forum_posts FROM anon;
REVOKE ALL ON TABLE public.forum_likes FROM anon;

REVOKE ALL ON TABLE public.forum_categories FROM authenticated;
REVOKE ALL ON TABLE public.forum_topics FROM authenticated;
REVOKE ALL ON TABLE public.forum_posts FROM authenticated;
REVOKE ALL ON TABLE public.forum_likes FROM authenticated;

GRANT SELECT ON TABLE public.forum_categories TO anon;
GRANT SELECT ON TABLE public.forum_topics TO anon;
GRANT SELECT ON TABLE public.forum_posts TO anon;
GRANT SELECT ON TABLE public.forum_likes TO anon;

GRANT SELECT ON TABLE public.forum_categories TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.forum_topics TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.forum_posts TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.forum_likes TO authenticated;
GRANT ALL ON TABLE public.forum_categories TO service_role;
GRANT ALL ON TABLE public.forum_topics TO service_role;
GRANT ALL ON TABLE public.forum_posts TO service_role;
GRANT ALL ON TABLE public.forum_likes TO service_role;

DROP POLICY IF EXISTS "Forum categories are publicly readable" ON public.forum_categories;
CREATE POLICY "Forum categories are publicly readable"
  ON public.forum_categories
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Forum topics are publicly readable" ON public.forum_topics;
CREATE POLICY "Forum topics are publicly readable"
  ON public.forum_topics
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can create forum topics" ON public.forum_topics;
CREATE POLICY "Authenticated users can create forum topics"
  ON public.forum_topics
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Owners can update forum topics" ON public.forum_topics;
CREATE POLICY "Owners can update forum topics"
  ON public.forum_topics
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Owners or admins can delete forum topics" ON public.forum_topics;
CREATE POLICY "Owners or admins can delete forum topics"
  ON public.forum_topics
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Forum posts are publicly readable" ON public.forum_posts;
CREATE POLICY "Forum posts are publicly readable"
  ON public.forum_posts
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can create forum posts" ON public.forum_posts;
CREATE POLICY "Authenticated users can create forum posts"
  ON public.forum_posts
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Owners can update forum posts" ON public.forum_posts;
CREATE POLICY "Owners can update forum posts"
  ON public.forum_posts
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Owners or admins can delete forum posts" ON public.forum_posts;
CREATE POLICY "Owners or admins can delete forum posts"
  ON public.forum_posts
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Forum likes are publicly readable" ON public.forum_likes;
CREATE POLICY "Forum likes are publicly readable"
  ON public.forum_likes
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Authenticated users can like forum posts" ON public.forum_likes;
CREATE POLICY "Authenticated users can like forum posts"
  ON public.forum_likes
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Owners or admins can delete forum likes" ON public.forum_likes;
CREATE POLICY "Owners or admins can delete forum likes"
  ON public.forum_likes
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

COMMIT;
