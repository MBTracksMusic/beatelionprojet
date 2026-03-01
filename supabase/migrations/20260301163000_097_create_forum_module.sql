/*
  # Create production-ready forum module

  Features:
  - Categories, topics, posts, likes
  - Premium category gating using active producer subscriptions
  - Secure RLS for anon/authenticated/admin flows
  - Trigger-maintained topic counters for scalable pagination

  Notes:
  - Premium access is granted to admins and to users with an active/trialing
    producer subscription whose current_period_end is still in the future.
  - Public read remains available for non-premium categories.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.forum_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (btrim(name) <> ''),
  slug text NOT NULL UNIQUE CHECK (btrim(slug) <> ''),
  description text,
  is_premium_only boolean NOT NULL DEFAULT false,
  position integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_topics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES public.forum_categories(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (btrim(title) <> ''),
  slug text NOT NULL CHECK (btrim(slug) <> ''),
  is_pinned boolean NOT NULL DEFAULT false,
  is_locked boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_post_at timestamptz NOT NULL DEFAULT now(),
  post_count integer NOT NULL DEFAULT 0 CHECK (post_count >= 0),
  CONSTRAINT forum_topics_category_slug_key UNIQUE (category_id, slug)
);

CREATE TABLE IF NOT EXISTS public.forum_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (btrim(content) <> ''),
  edited_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_post_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT forum_post_likes_post_user_key UNIQUE (post_id, user_id)
);

-- ---------------------------------------------------------------------------
-- 2) Indexes for pagination and common lookups
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_forum_categories_position
  ON public.forum_categories (position, created_at);

CREATE INDEX IF NOT EXISTS idx_forum_topics_category_last_post_desc
  ON public.forum_topics (category_id, is_pinned DESC, last_post_at DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_topics_user_created_desc
  ON public.forum_topics (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_created_asc
  ON public.forum_posts (topic_id, created_at ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_forum_posts_user_created_desc
  ON public.forum_posts (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_visible_created
  ON public.forum_posts (topic_id, created_at DESC)
  WHERE is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_forum_post_likes_post_created_desc
  ON public.forum_post_likes (post_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_post_likes_user_created_desc
  ON public.forum_post_likes (user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 3) Helper functions used by RLS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.forum_has_active_subscription(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT
    CASE
      WHEN p_user_id IS NULL THEN false
      WHEN public.is_admin(p_user_id) THEN true
      ELSE EXISTS (
        SELECT 1
        FROM public.producer_subscriptions ps
        WHERE ps.user_id = p_user_id
          AND ps.subscription_status IN ('active', 'trialing')
          AND ps.current_period_end > now()
      )
    END;
$$;

CREATE OR REPLACE FUNCTION public.forum_can_access_category(
  p_category_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.forum_categories fc
    WHERE fc.id = p_category_id
      AND (
        fc.is_premium_only = false
        OR public.forum_has_active_subscription(p_user_id)
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.forum_can_write_topic(
  p_topic_id uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.forum_topics ft
    JOIN public.forum_categories fc ON fc.id = ft.category_id
    WHERE ft.id = p_topic_id
      AND ft.is_locked = false
      AND (
        fc.is_premium_only = false
        OR public.forum_has_active_subscription(p_user_id)
      )
  );
$$;

REVOKE EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Trigger-maintained counters
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recalculate_forum_topic_stats(p_topic_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_created_at timestamptz;
  v_post_count integer;
  v_last_post_at timestamptz;
BEGIN
  IF p_topic_id IS NULL THEN
    RETURN;
  END IF;

  SELECT ft.created_at
  INTO v_created_at
  FROM public.forum_topics ft
  WHERE ft.id = p_topic_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE fp.is_deleted = false),
    MAX(fp.created_at) FILTER (WHERE fp.is_deleted = false)
  INTO v_post_count, v_last_post_at
  FROM public.forum_posts fp
  WHERE fp.topic_id = p_topic_id;

  UPDATE public.forum_topics
  SET
    post_count = COALESCE(v_post_count, 0),
    last_post_at = COALESCE(v_last_post_at, v_created_at)
  WHERE id = p_topic_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_forum_post_stats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.recalculate_forum_topic_stats(NEW.topic_id);
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.topic_id IS DISTINCT FROM NEW.topic_id THEN
      PERFORM public.recalculate_forum_topic_stats(OLD.topic_id);
    END IF;
    PERFORM public.recalculate_forum_topic_stats(NEW.topic_id);
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    PERFORM public.recalculate_forum_topic_stats(OLD.topic_id);
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS forum_posts_recalculate_topic_stats ON public.forum_posts;

CREATE TRIGGER forum_posts_recalculate_topic_stats
  AFTER INSERT OR UPDATE OF topic_id, is_deleted OR DELETE
  ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_forum_post_stats();

REVOKE EXECUTE ON FUNCTION public.recalculate_forum_topic_stats(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_forum_post_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.recalculate_forum_topic_stats(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.handle_forum_post_stats() TO service_role;

-- ---------------------------------------------------------------------------
-- 5) RLS + grants
-- ---------------------------------------------------------------------------
ALTER TABLE public.forum_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_post_likes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.forum_categories FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_topics FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_posts FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_post_likes FROM PUBLIC;

REVOKE ALL ON TABLE public.forum_categories FROM anon;
REVOKE ALL ON TABLE public.forum_topics FROM anon;
REVOKE ALL ON TABLE public.forum_posts FROM anon;
REVOKE ALL ON TABLE public.forum_post_likes FROM anon;

REVOKE ALL ON TABLE public.forum_categories FROM authenticated;
REVOKE ALL ON TABLE public.forum_topics FROM authenticated;
REVOKE ALL ON TABLE public.forum_posts FROM authenticated;
REVOKE ALL ON TABLE public.forum_post_likes FROM authenticated;

GRANT SELECT ON TABLE public.forum_categories TO anon;
GRANT SELECT ON TABLE public.forum_topics TO anon;
GRANT SELECT ON TABLE public.forum_posts TO anon;
GRANT SELECT ON TABLE public.forum_post_likes TO anon;

GRANT SELECT ON TABLE public.forum_categories TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.forum_topics TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.forum_posts TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.forum_post_likes TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) Policies: categories
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum categories readable" ON public.forum_categories;
CREATE POLICY "Forum categories readable"
  ON public.forum_categories
  FOR SELECT
  TO anon, authenticated
  USING (
    is_premium_only = false
    OR public.forum_has_active_subscription(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 7) Policies: topics
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum topics readable" ON public.forum_topics;
CREATE POLICY "Forum topics readable"
  ON public.forum_topics
  FOR SELECT
  TO anon, authenticated
  USING (
    public.forum_can_access_category(category_id, auth.uid())
  );

DROP POLICY IF EXISTS "Authenticated users can create forum topics" ON public.forum_topics;
CREATE POLICY "Authenticated users can create forum topics"
  ON public.forum_topics
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND public.forum_can_access_category(category_id, auth.uid())
  );

DROP POLICY IF EXISTS "Authors or admins can delete forum topics" ON public.forum_topics;
CREATE POLICY "Authors or admins can delete forum topics"
  ON public.forum_topics
  FOR DELETE
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 8) Policies: posts
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum posts readable" ON public.forum_posts;
CREATE POLICY "Forum posts readable"
  ON public.forum_posts
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.forum_topics ft
      WHERE ft.id = forum_posts.topic_id
        AND public.forum_can_access_category(ft.category_id, auth.uid())
    )
  );

DROP POLICY IF EXISTS "Authenticated users can create forum posts" ON public.forum_posts;
CREATE POLICY "Authenticated users can create forum posts"
  ON public.forum_posts
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND public.forum_can_write_topic(topic_id, auth.uid())
  );

DROP POLICY IF EXISTS "Authors or admins can edit forum posts" ON public.forum_posts;
CREATE POLICY "Authors or admins can edit forum posts"
  ON public.forum_posts
  FOR UPDATE
  TO authenticated
  USING (
    (
      user_id = auth.uid()
      AND EXISTS (
        SELECT 1
        FROM public.forum_topics ft
        WHERE ft.id = forum_posts.topic_id
          AND ft.is_locked = false
      )
    )
    OR public.is_admin(auth.uid())
  )
  WITH CHECK (
    (
      user_id = auth.uid()
      AND public.forum_can_write_topic(topic_id, auth.uid())
    )
    OR public.is_admin(auth.uid())
  );

DROP POLICY IF EXISTS "Authors or admins can delete forum posts" ON public.forum_posts;
CREATE POLICY "Authors or admins can delete forum posts"
  ON public.forum_posts
  FOR DELETE
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_admin(auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 9) Policies: likes
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum post likes readable" ON public.forum_post_likes;
CREATE POLICY "Forum post likes readable"
  ON public.forum_post_likes
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.forum_posts fp
      JOIN public.forum_topics ft ON ft.id = fp.topic_id
      WHERE fp.id = forum_post_likes.post_id
        AND public.forum_can_access_category(ft.category_id, auth.uid())
    )
  );

DROP POLICY IF EXISTS "Authenticated users can like forum posts" ON public.forum_post_likes;
CREATE POLICY "Authenticated users can like forum posts"
  ON public.forum_post_likes
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.forum_posts fp
      JOIN public.forum_topics ft ON ft.id = fp.topic_id
      WHERE fp.id = forum_post_likes.post_id
        AND fp.is_deleted = false
        AND public.forum_can_write_topic(ft.id, auth.uid())
    )
  );

DROP POLICY IF EXISTS "Users or admins can unlike forum posts" ON public.forum_post_likes;
CREATE POLICY "Users or admins can unlike forum posts"
  ON public.forum_post_likes
  FOR DELETE
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_admin(auth.uid())
  );

COMMIT;
