/*
  # Forum reply user notifications

  Notifies a topic author when another visible, allowed forum post is added to
  their topic. The notification is emitted from Postgres so it also covers
  service-role writes from Edge Functions and assistant-generated replies.
*/

BEGIN;

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS entity_id uuid,
  ADD COLUMN IF NOT EXISTS target_url text;

CREATE INDEX IF NOT EXISTS notifications_user_type_created_at_idx
  ON public.notifications (user_id, type, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS notifications_user_type_entity_unique_idx
  ON public.notifications (user_id, type, entity_type, entity_id)
  WHERE entity_type IS NOT NULL
    AND entity_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_forum_topic_author_on_reply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_topic_author_id uuid;
  v_topic_title text;
  v_topic_slug text;
  v_category_slug text;
  v_reply_author_name text;
  v_target_url text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.is_visible IS TRUE
       AND OLD.is_deleted IS FALSE
       AND COALESCE(NULLIF(btrim(OLD.moderation_status), ''), 'allowed') = 'allowed' THEN
      RETURN NEW;
    END IF;
  END IF;

  IF NEW.topic_id IS NULL
     OR NEW.user_id IS NULL
     OR NEW.is_visible IS DISTINCT FROM true
     OR NEW.is_deleted IS TRUE
     OR COALESCE(NULLIF(btrim(NEW.moderation_status), ''), 'allowed') <> 'allowed' THEN
    RETURN NEW;
  END IF;

  SELECT
    ft.user_id,
    ft.title,
    ft.slug,
    fc.slug
  INTO
    v_topic_author_id,
    v_topic_title,
    v_topic_slug,
    v_category_slug
  FROM public.forum_topics ft
  JOIN public.forum_categories fc ON fc.id = ft.category_id
  WHERE ft.id = NEW.topic_id
    AND ft.is_deleted = false
  LIMIT 1;

  IF v_topic_author_id IS NULL OR v_topic_author_id = NEW.user_id THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(btrim(up.full_name), ''), NULLIF(btrim(up.username), ''), 'Un membre')
  INTO v_reply_author_name
  FROM public.user_profiles up
  WHERE up.id = NEW.user_id;

  v_reply_author_name := COALESCE(NULLIF(btrim(NEW.ai_agent_name), ''), v_reply_author_name, 'Un membre');
  v_topic_title := COALESCE(NULLIF(btrim(v_topic_title), ''), 'votre sujet');
  v_target_url := CASE
    WHEN NULLIF(btrim(v_category_slug), '') IS NOT NULL
      AND NULLIF(btrim(v_topic_slug), '') IS NOT NULL
      THEN '/forum/' || v_category_slug || '/' || v_topic_slug
    ELSE NULL
  END;

  BEGIN
    INSERT INTO public.notifications (
      user_id,
      type,
      title,
      message,
      entity_type,
      entity_id,
      target_url
    )
    VALUES (
      v_topic_author_id,
      'forum_topic_reply',
      'Nouvelle reponse sur votre sujet',
      format('%s a repondu a "%s".', v_reply_author_name, v_topic_title),
      'forum_post',
      NEW.id,
      v_target_url
    )
    ON CONFLICT (user_id, type, entity_type, entity_id)
      WHERE entity_type IS NOT NULL
        AND entity_id IS NOT NULL
      DO NOTHING;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'forum reply notification failed for post %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_forum_reply_notify_topic_author ON public.forum_posts;
CREATE TRIGGER on_forum_reply_notify_topic_author
  AFTER INSERT OR UPDATE OF moderation_status, is_visible, is_deleted
  ON public.forum_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_forum_topic_author_on_reply();

COMMIT;
