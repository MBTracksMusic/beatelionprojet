/*
  # Forum Agents base hardening

  Goals:
  - Re-assert the strong forum RLS model from migration 097.
  - Neutralize permissive forum policies introduced later.
  - Add moderation and assistant metadata/tables.
  - Remove direct client writes on forum_topics / forum_posts.
  - Provide RPCs for server-side forum writes and admin moderation.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Schema extensions
-- ---------------------------------------------------------------------------
ALTER TABLE public.forum_topics
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_ai_reply_at timestamptz;

ALTER TABLE public.forum_posts
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS moderation_status text NOT NULL DEFAULT 'pending'
    CHECK (moderation_status IN ('pending', 'allowed', 'review', 'blocked')),
  ADD COLUMN IF NOT EXISTS is_visible boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS is_flagged boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS moderation_score numeric(5,4),
  ADD COLUMN IF NOT EXISTS moderation_reason text,
  ADD COLUMN IF NOT EXISTS moderated_at timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_model text,
  ADD COLUMN IF NOT EXISTS is_ai_generated boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ai_agent_name text,
  ADD COLUMN IF NOT EXISTS source_post_id uuid REFERENCES public.forum_posts(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.forum_moderation_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  topic_id uuid REFERENCES public.forum_topics(id) ON DELETE SET NULL,
  source text NOT NULL,
  model text,
  score numeric(5,4) CHECK (score IS NULL OR (score >= 0 AND score <= 1)),
  decision text NOT NULL,
  reason text,
  raw_response jsonb NOT NULL DEFAULT '{}'::jsonb,
  reviewed_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.forum_assistant_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_id uuid NOT NULL REFERENCES public.forum_topics(id) ON DELETE CASCADE,
  source_post_id uuid REFERENCES public.forum_posts(id) ON DELETE SET NULL,
  trigger_type text NOT NULL CHECK (trigger_type IN ('mention', 'no_reply_cron')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  idempotency_key text NOT NULL UNIQUE,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_forum_posts_topic_visible_desc
  ON public.forum_posts (topic_id, created_at DESC)
  WHERE is_deleted = false AND is_visible = true;

CREATE INDEX IF NOT EXISTS idx_forum_assistant_jobs_status_created
  ON public.forum_assistant_jobs (status, created_at);

CREATE INDEX IF NOT EXISTS idx_forum_moderation_logs_post_created
  ON public.forum_moderation_logs (post_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_forum_moderation_logs_topic_created
  ON public.forum_moderation_logs (topic_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 2) Seed app settings and rate limits
-- ---------------------------------------------------------------------------
INSERT INTO public.app_settings (key, value)
VALUES (
  'forum_moderation_settings',
  jsonb_build_object(
    'review_threshold', 0.45,
    'block_threshold', 0.85,
    'openai_moderation_model', 'omni-moderation-latest',
    'assistant_model', 'gpt-5-mini'
  )
)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.app_settings (key, value)
VALUES (
  'forum_assistant_settings',
  jsonb_build_object(
    'assistant_name', 'LevelUp Assistant',
    'assistant_email', 'forum-assistant@levelupmusic.local',
    'assistant_username', 'levelup_assistant',
    'assistant_user_id', null,
    'mention_cooldown_hours', 12
  )
)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.rpc_rate_limit_rules (rpc_name, scope, allowed_per_minute, is_enabled)
VALUES
  ('forum_create_topic', 'per_admin', 6, true),
  ('forum_create_post', 'per_admin', 20, true),
  ('forum_assistant_dispatch', 'per_admin', 20, true),
  ('forum_assistant_worker', 'global', 60, true)
ON CONFLICT (rpc_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Helper functions and triggers
-- ---------------------------------------------------------------------------
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

CREATE OR REPLACE FUNCTION public.forum_is_assistant_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_settings s
    WHERE s.key = 'forum_assistant_settings'
      AND NULLIF(s.value->>'assistant_user_id', '') IS NOT NULL
      AND (s.value->>'assistant_user_id')::uuid = p_user_id
  );
$$;

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
      WHEN public.forum_is_assistant_user(p_user_id) THEN true
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
      AND COALESCE(ft.is_deleted, false) = false
      AND ft.is_locked = false
      AND (
        fc.is_premium_only = false
        OR public.forum_has_active_subscription(p_user_id)
      )
  );
$$;

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
    COUNT(*) FILTER (WHERE fp.is_deleted = false AND fp.is_visible = true),
    MAX(fp.created_at) FILTER (WHERE fp.is_deleted = false AND fp.is_visible = true)
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
  AFTER INSERT OR UPDATE OF topic_id, is_deleted, is_visible OR DELETE
  ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_forum_post_stats();

REVOKE EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_is_assistant_user(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.recalculate_forum_topic_stats(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.handle_forum_post_stats() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.forum_is_assistant_user(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_is_assistant_user(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_is_assistant_user(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_has_active_subscription(uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_access_category(uuid, uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_can_write_topic(uuid, uuid) TO service_role;

GRANT EXECUTE ON FUNCTION public.recalculate_forum_topic_stats(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.handle_forum_post_stats() TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Grants and RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.forum_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_moderation_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.forum_assistant_jobs ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_topics FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_topics FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_topics FROM authenticated;

REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_posts FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_posts FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.forum_posts FROM authenticated;

GRANT SELECT ON TABLE public.forum_topics TO anon;
GRANT SELECT ON TABLE public.forum_posts TO anon;
GRANT SELECT ON TABLE public.forum_topics TO authenticated;
GRANT SELECT ON TABLE public.forum_posts TO authenticated;
GRANT ALL ON TABLE public.forum_topics TO service_role;
GRANT ALL ON TABLE public.forum_posts TO service_role;

REVOKE ALL ON TABLE public.forum_moderation_logs FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_moderation_logs FROM anon;
REVOKE ALL ON TABLE public.forum_moderation_logs FROM authenticated;
GRANT SELECT ON TABLE public.forum_moderation_logs TO authenticated;
GRANT ALL ON TABLE public.forum_moderation_logs TO service_role;

REVOKE ALL ON TABLE public.forum_assistant_jobs FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_assistant_jobs FROM anon;
REVOKE ALL ON TABLE public.forum_assistant_jobs FROM authenticated;
GRANT SELECT ON TABLE public.forum_assistant_jobs TO authenticated;
GRANT ALL ON TABLE public.forum_assistant_jobs TO service_role;

DROP POLICY IF EXISTS "Forum categories readable" ON public.forum_categories;
DROP POLICY IF EXISTS "Forum categories are publicly readable" ON public.forum_categories;
CREATE POLICY "Forum categories readable"
  ON public.forum_categories
  FOR SELECT
  TO anon, authenticated
  USING (
    is_premium_only = false
    OR public.forum_has_active_subscription(auth.uid())
  );

DROP POLICY IF EXISTS "Forum topics readable" ON public.forum_topics;
DROP POLICY IF EXISTS "Forum topics are publicly readable" ON public.forum_topics;
DROP POLICY IF EXISTS "Authenticated users can create forum topics" ON public.forum_topics;
DROP POLICY IF EXISTS "Owners can update forum topics" ON public.forum_topics;
DROP POLICY IF EXISTS "Authors or admins can delete forum topics" ON public.forum_topics;
DROP POLICY IF EXISTS "Owners or admins can delete forum topics" ON public.forum_topics;

CREATE POLICY "Forum topics readable"
  ON public.forum_topics
  FOR SELECT
  TO anon, authenticated
  USING (
    public.forum_can_access_category(category_id, auth.uid())
    AND (
      (
        forum_topics.is_deleted = false
        AND EXISTS (
          SELECT 1
          FROM public.forum_posts fp
          WHERE fp.topic_id = forum_topics.id
            AND (
              fp.is_deleted = true
              OR (fp.is_deleted = false AND fp.is_visible = true)
            )
        )
      )
      OR forum_topics.user_id = auth.uid()
      OR public.is_admin(auth.uid())
    )
  );

DROP POLICY IF EXISTS "Forum posts readable" ON public.forum_posts;
DROP POLICY IF EXISTS "Forum posts are publicly readable" ON public.forum_posts;
DROP POLICY IF EXISTS "Authenticated users can create forum posts" ON public.forum_posts;
DROP POLICY IF EXISTS "Owners can update forum posts" ON public.forum_posts;
DROP POLICY IF EXISTS "Authors or admins can edit forum posts" ON public.forum_posts;
DROP POLICY IF EXISTS "Owners or admins can delete forum posts" ON public.forum_posts;
DROP POLICY IF EXISTS "Authors or admins can delete forum posts" ON public.forum_posts;

CREATE POLICY "Forum posts readable"
  ON public.forum_posts
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.forum_topics ft
      WHERE ft.id = forum_posts.topic_id
        AND ft.is_deleted = false
        AND public.forum_can_access_category(ft.category_id, auth.uid())
    )
    AND (
      public.is_admin(auth.uid())
      OR forum_posts.user_id = auth.uid()
      OR forum_posts.is_deleted = true
      OR forum_posts.is_visible = true
    )
  );

DROP POLICY IF EXISTS "Admins can read forum moderation logs" ON public.forum_moderation_logs;
CREATE POLICY "Admins can read forum moderation logs"
  ON public.forum_moderation_logs
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can read forum assistant jobs" ON public.forum_assistant_jobs;
CREATE POLICY "Admins can read forum assistant jobs"
  ON public.forum_assistant_jobs
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

-- ---------------------------------------------------------------------------
-- 5) RPCs used by Edge Functions and admin tools
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_forum_create_topic(
  p_user_id uuid,
  p_category_slug text,
  p_title text,
  p_topic_slug text,
  p_content text,
  p_source text,
  p_moderation_status text DEFAULT 'allowed',
  p_is_visible boolean DEFAULT true,
  p_is_flagged boolean DEFAULT false,
  p_moderation_score numeric DEFAULT NULL,
  p_moderation_reason text DEFAULT NULL,
  p_moderation_model text DEFAULT NULL,
  p_is_ai_generated boolean DEFAULT false,
  p_ai_agent_name text DEFAULT NULL,
  p_source_post_id uuid DEFAULT NULL,
  p_raw_response jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  topic_id uuid,
  topic_slug text,
  category_id uuid,
  category_slug text,
  post_id uuid,
  moderation_status text,
  is_visible boolean,
  is_flagged boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_category public.forum_categories%ROWTYPE;
  v_topic_id uuid;
  v_post_id uuid;
BEGIN
  IF v_jwt_role <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  IF p_category_slug IS NULL OR btrim(p_category_slug) = '' THEN
    RAISE EXCEPTION 'category_required';
  END IF;

  IF p_title IS NULL OR btrim(p_title) = '' THEN
    RAISE EXCEPTION 'title_required';
  END IF;

  IF p_topic_slug IS NULL OR btrim(p_topic_slug) = '' THEN
    RAISE EXCEPTION 'topic_slug_required';
  END IF;

  IF p_content IS NULL OR btrim(p_content) = '' THEN
    RAISE EXCEPTION 'content_required';
  END IF;

  SELECT *
  INTO v_category
  FROM public.forum_categories
  WHERE slug = p_category_slug
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'category_not_found';
  END IF;

  IF NOT public.forum_can_access_category(v_category.id, p_user_id) THEN
    RAISE EXCEPTION 'category_access_denied';
  END IF;

  INSERT INTO public.forum_topics (
    category_id,
    user_id,
    title,
    slug
  )
  VALUES (
    v_category.id,
    p_user_id,
    btrim(p_title),
    btrim(p_topic_slug)
  )
  RETURNING id INTO v_topic_id;

  INSERT INTO public.forum_posts (
    topic_id,
    user_id,
    content,
    moderation_status,
    is_visible,
    is_flagged,
    moderation_score,
    moderation_reason,
    moderated_at,
    moderation_model,
    is_ai_generated,
    ai_agent_name,
    source_post_id
  )
  VALUES (
    v_topic_id,
    p_user_id,
    btrim(p_content),
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    COALESCE(p_is_visible, true),
    COALESCE(p_is_flagged, false),
    p_moderation_score,
    p_moderation_reason,
    now(),
    p_moderation_model,
    COALESCE(p_is_ai_generated, false),
    p_ai_agent_name,
    p_source_post_id
  )
  RETURNING id INTO v_post_id;

  IF COALESCE(p_is_ai_generated, false) THEN
    UPDATE public.forum_topics
    SET last_ai_reply_at = now()
    WHERE id = v_topic_id;
  END IF;

  INSERT INTO public.forum_moderation_logs (
    post_id,
    topic_id,
    source,
    model,
    score,
    decision,
    reason,
    raw_response
  )
  VALUES (
    v_post_id,
    v_topic_id,
    COALESCE(NULLIF(btrim(COALESCE(p_source, '')), ''), 'forum_rpc'),
    p_moderation_model,
    p_moderation_score,
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    p_moderation_reason,
    COALESCE(p_raw_response, '{}'::jsonb)
  );

  RETURN QUERY
  SELECT
    v_topic_id,
    p_topic_slug,
    v_category.id,
    v_category.slug,
    v_post_id,
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    COALESCE(p_is_visible, true),
    COALESCE(p_is_flagged, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_forum_create_post(
  p_user_id uuid,
  p_topic_id uuid,
  p_content text,
  p_source text,
  p_moderation_status text DEFAULT 'allowed',
  p_is_visible boolean DEFAULT true,
  p_is_flagged boolean DEFAULT false,
  p_moderation_score numeric DEFAULT NULL,
  p_moderation_reason text DEFAULT NULL,
  p_moderation_model text DEFAULT NULL,
  p_is_ai_generated boolean DEFAULT false,
  p_ai_agent_name text DEFAULT NULL,
  p_source_post_id uuid DEFAULT NULL,
  p_raw_response jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  post_id uuid,
  topic_id uuid,
  topic_slug text,
  category_slug text,
  moderation_status text,
  is_visible boolean,
  is_flagged boolean,
  is_ai_generated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_topic public.forum_topics%ROWTYPE;
  v_category public.forum_categories%ROWTYPE;
  v_post_id uuid;
BEGIN
  IF v_jwt_role <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  IF p_topic_id IS NULL THEN
    RAISE EXCEPTION 'topic_required';
  END IF;

  IF p_content IS NULL OR btrim(p_content) = '' THEN
    RAISE EXCEPTION 'content_required';
  END IF;

  SELECT *
  INTO v_topic
  FROM public.forum_topics
  WHERE id = p_topic_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'topic_not_found';
  END IF;

  IF v_topic.is_deleted THEN
    RAISE EXCEPTION 'topic_deleted';
  END IF;

  IF NOT public.forum_can_write_topic(v_topic.id, p_user_id) THEN
    RAISE EXCEPTION 'topic_write_denied';
  END IF;

  SELECT *
  INTO v_category
  FROM public.forum_categories
  WHERE id = v_topic.category_id
  LIMIT 1;

  INSERT INTO public.forum_posts (
    topic_id,
    user_id,
    content,
    moderation_status,
    is_visible,
    is_flagged,
    moderation_score,
    moderation_reason,
    moderated_at,
    moderation_model,
    is_ai_generated,
    ai_agent_name,
    source_post_id
  )
  VALUES (
    v_topic.id,
    p_user_id,
    btrim(p_content),
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    COALESCE(p_is_visible, true),
    COALESCE(p_is_flagged, false),
    p_moderation_score,
    p_moderation_reason,
    now(),
    p_moderation_model,
    COALESCE(p_is_ai_generated, false),
    p_ai_agent_name,
    p_source_post_id
  )
  RETURNING id INTO v_post_id;

  IF COALESCE(p_is_ai_generated, false) THEN
    UPDATE public.forum_topics
    SET last_ai_reply_at = now()
    WHERE id = v_topic.id;
  END IF;

  INSERT INTO public.forum_moderation_logs (
    post_id,
    topic_id,
    source,
    model,
    score,
    decision,
    reason,
    raw_response
  )
  VALUES (
    v_post_id,
    v_topic.id,
    COALESCE(NULLIF(btrim(COALESCE(p_source, '')), ''), 'forum_rpc'),
    p_moderation_model,
    p_moderation_score,
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    p_moderation_reason,
    COALESCE(p_raw_response, '{}'::jsonb)
  );

  RETURN QUERY
  SELECT
    v_post_id,
    v_topic.id,
    v_topic.slug,
    v_category.slug,
    COALESCE(NULLIF(btrim(COALESCE(p_moderation_status, '')), ''), 'allowed'),
    COALESCE(p_is_visible, true),
    COALESCE(p_is_flagged, false),
    COALESCE(p_is_ai_generated, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_admin_set_post_state(
  p_post_id uuid,
  p_action text
)
RETURNS public.forum_posts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_post public.forum_posts%ROWTYPE;
  v_action text := lower(COALESCE(p_action, ''));
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT *
  INTO v_post
  FROM public.forum_posts
  WHERE id = p_post_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'post_not_found';
  END IF;

  IF v_action = 'approve' THEN
    UPDATE public.forum_posts
    SET
      is_deleted = false,
      is_visible = true,
      is_flagged = false,
      moderation_status = 'allowed',
      moderation_reason = 'approved_by_admin',
      moderated_at = now()
    WHERE id = p_post_id
    RETURNING * INTO v_post;
  ELSIF v_action = 'block' THEN
    UPDATE public.forum_posts
    SET
      is_visible = false,
      is_flagged = true,
      moderation_status = 'blocked',
      moderation_reason = 'blocked_by_admin',
      moderated_at = now()
    WHERE id = p_post_id
    RETURNING * INTO v_post;
  ELSIF v_action = 'delete' THEN
    UPDATE public.forum_posts
    SET
      is_deleted = true,
      is_visible = true,
      is_flagged = true,
      moderation_status = CASE
        WHEN moderation_status = 'allowed' THEN 'blocked'
        ELSE moderation_status
      END,
      moderation_reason = 'deleted_by_admin',
      moderated_at = now()
    WHERE id = p_post_id
    RETURNING * INTO v_post;
  ELSIF v_action = 'restore' THEN
    UPDATE public.forum_posts
    SET
      is_deleted = false,
      is_visible = true,
      is_flagged = false,
      moderation_status = 'allowed',
      moderation_reason = 'restored_by_admin',
      moderated_at = now()
    WHERE id = p_post_id
    RETURNING * INTO v_post;
  ELSE
    RAISE EXCEPTION 'invalid_action';
  END IF;

  INSERT INTO public.forum_moderation_logs (
    post_id,
    topic_id,
    source,
    model,
    decision,
    reason,
    reviewed_by,
    reviewed_at,
    raw_response
  )
  VALUES (
    v_post.id,
    v_post.topic_id,
    'forum_admin',
    'human',
    v_action,
    COALESCE(v_post.moderation_reason, v_action),
    v_actor,
    now(),
    jsonb_build_object('action', v_action)
  );

  RETURN v_post;
END;
$$;

CREATE OR REPLACE FUNCTION public.forum_admin_set_topic_deleted(
  p_topic_id uuid,
  p_is_deleted boolean
)
RETURNS public.forum_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_topic public.forum_topics%ROWTYPE;
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  UPDATE public.forum_topics
  SET
    is_deleted = COALESCE(p_is_deleted, true),
    deleted_at = CASE WHEN COALESCE(p_is_deleted, true) THEN now() ELSE NULL END,
    deleted_by = CASE WHEN COALESCE(p_is_deleted, true) THEN v_actor ELSE NULL END
  WHERE id = p_topic_id
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'topic_not_found';
  END IF;

  INSERT INTO public.forum_moderation_logs (
    post_id,
    topic_id,
    source,
    model,
    decision,
    reason,
    reviewed_by,
    reviewed_at,
    raw_response
  )
  VALUES (
    NULL,
    v_topic.id,
    'forum_admin',
    'human',
    CASE WHEN COALESCE(p_is_deleted, true) THEN 'topic_delete' ELSE 'topic_restore' END,
    CASE WHEN COALESCE(p_is_deleted, true) THEN 'topic_deleted_by_admin' ELSE 'topic_restored_by_admin' END,
    v_actor,
    now(),
    jsonb_build_object('is_deleted', COALESCE(p_is_deleted, true))
  );

  RETURN v_topic;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_topic(uuid, text, text, text, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_topic(uuid, text, text, text, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_topic(uuid, text, text, text, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_forum_create_topic(uuid, text, text, text, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_post(uuid, uuid, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_post(uuid, uuid, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.rpc_forum_create_post(uuid, uuid, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_forum_create_post(uuid, uuid, text, text, text, boolean, boolean, numeric, text, text, boolean, text, uuid, jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.forum_admin_set_post_state(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_admin_set_post_state(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.forum_admin_set_post_state(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_set_post_state(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_set_post_state(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.forum_admin_set_topic_deleted(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.forum_admin_set_topic_deleted(uuid, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.forum_admin_set_topic_deleted(uuid, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_set_topic_deleted(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_set_topic_deleted(uuid, boolean) TO service_role;

COMMIT;
