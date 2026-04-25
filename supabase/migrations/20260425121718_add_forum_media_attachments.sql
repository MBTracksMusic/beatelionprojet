/*
  # Forum media attachments

  Adds one optional image/video attachment per forum post.
  Media stays in a private bucket and is readable only through forum access
  rules. Admins control availability per category with forum_categories.allow_media.
*/

BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'forum-media',
  'forum-media',
  false,
  52428800,
  ARRAY[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'video/mp4',
    'video/webm',
    'video/quicktime'
  ]::text[]
)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

CREATE TABLE IF NOT EXISTS public.forum_post_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.forum_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  bucket text NOT NULL DEFAULT 'forum-media',
  storage_path text NOT NULL UNIQUE,
  media_type text NOT NULL CHECK (media_type IN ('image', 'video')),
  mime_type text NOT NULL CHECK (
    mime_type IN (
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
      'video/mp4',
      'video/webm',
      'video/quicktime'
    )
  ),
  file_size bigint NOT NULL CHECK (file_size > 0 AND file_size <= 52428800),
  original_filename text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT forum_post_attachments_one_per_post UNIQUE (post_id)
);

CREATE INDEX IF NOT EXISTS idx_forum_post_attachments_post
  ON public.forum_post_attachments (post_id);

CREATE INDEX IF NOT EXISTS idx_forum_post_attachments_user_created
  ON public.forum_post_attachments (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.enforce_forum_post_attachment_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_post_user_id uuid;
  v_allow_media boolean;
BEGIN
  IF NEW.bucket <> 'forum-media' THEN
    RAISE EXCEPTION 'invalid_forum_media_bucket';
  END IF;

  IF NEW.storage_path IS NULL
     OR NEW.storage_path NOT LIKE 'posts/' || NEW.post_id::text || '/%' THEN
    RAISE EXCEPTION 'invalid_forum_media_path';
  END IF;

  SELECT fp.user_id, COALESCE(fc.allow_media, true)
  INTO v_post_user_id, v_allow_media
  FROM public.forum_posts fp
  JOIN public.forum_topics ft ON ft.id = fp.topic_id
  JOIN public.forum_categories fc ON fc.id = ft.category_id
  WHERE fp.id = NEW.post_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'post_not_found';
  END IF;

  IF v_allow_media = false THEN
    RAISE EXCEPTION 'media_not_allowed';
  END IF;

  IF NEW.user_id IS DISTINCT FROM v_post_user_id THEN
    RAISE EXCEPTION 'attachment_user_mismatch';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS forum_post_attachments_enforce_rules ON public.forum_post_attachments;
CREATE TRIGGER forum_post_attachments_enforce_rules
  BEFORE INSERT OR UPDATE ON public.forum_post_attachments
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_forum_post_attachment_rules();

ALTER TABLE public.forum_post_attachments ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.forum_post_attachments FROM PUBLIC;
REVOKE ALL ON TABLE public.forum_post_attachments FROM anon;
REVOKE ALL ON TABLE public.forum_post_attachments FROM authenticated;
GRANT SELECT ON TABLE public.forum_post_attachments TO anon;
GRANT SELECT ON TABLE public.forum_post_attachments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.forum_post_attachments TO service_role;

DROP POLICY IF EXISTS "Forum post attachments readable" ON public.forum_post_attachments;
CREATE POLICY "Forum post attachments readable"
  ON public.forum_post_attachments
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.forum_posts fp
      JOIN public.forum_topics ft ON ft.id = fp.topic_id
      JOIN public.forum_categories fc ON fc.id = ft.category_id
      WHERE fp.id = forum_post_attachments.post_id
        AND COALESCE(fc.allow_media, true) = true
        AND public.forum_can_access_category(ft.category_id, auth.uid())
        AND (
          public.is_admin(auth.uid())
          OR fp.user_id = auth.uid()
          OR (
            COALESCE(fp.is_deleted, false) = false
            AND COALESCE(fp.is_visible, true) = true
          )
        )
    )
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'storage'
      AND table_name = 'objects'
  ) THEN
    RAISE NOTICE 'storage.objects not found; skipping forum-media storage policies.';
    RETURN;
  END IF;

  DROP POLICY IF EXISTS "Users can upload pending forum media" ON storage.objects;
  CREATE POLICY "Users can upload pending forum media"
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = 'forum-media'
      AND auth.uid() = owner
      AND name LIKE 'pending/' || auth.uid()::text || '/%'
    );

  DROP POLICY IF EXISTS "Users can read own pending forum media" ON storage.objects;
  CREATE POLICY "Users can read own pending forum media"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'forum-media'
      AND auth.uid() = owner
      AND name LIKE 'pending/' || auth.uid()::text || '/%'
    );

  DROP POLICY IF EXISTS "Users can delete own pending forum media" ON storage.objects;
  CREATE POLICY "Users can delete own pending forum media"
    ON storage.objects
    FOR DELETE
    TO authenticated
    USING (
      bucket_id = 'forum-media'
      AND auth.uid() = owner
      AND name LIKE 'pending/' || auth.uid()::text || '/%'
    );

  DROP POLICY IF EXISTS "Forum media readable by forum access" ON storage.objects;
  CREATE POLICY "Forum media readable by forum access"
    ON storage.objects
    FOR SELECT
    TO anon, authenticated
    USING (
      bucket_id = 'forum-media'
      AND EXISTS (
        SELECT 1
        FROM public.forum_post_attachments fpa
        JOIN public.forum_posts fp ON fp.id = fpa.post_id
        JOIN public.forum_topics ft ON ft.id = fp.topic_id
        JOIN public.forum_categories fc ON fc.id = ft.category_id
        WHERE fpa.bucket = 'forum-media'
          AND fpa.storage_path = storage.objects.name
          AND COALESCE(fc.allow_media, true) = true
          AND public.forum_can_access_category(ft.category_id, auth.uid())
          AND (
            public.is_admin(auth.uid())
            OR fp.user_id = auth.uid()
            OR (
              COALESCE(fp.is_deleted, false) = false
              AND COALESCE(fp.is_visible, true) = true
            )
          )
      )
    );
END
$$;

COMMIT;
