/*
  # Rollback to pre-023/024 audio model (legacy master_url + beats-audio playback)

  This migration restores the legacy behavior used before migrations 023/024:
  - beats-audio as public playback bucket
  - authenticated read policy on beats-audio
  - producers can read their own audio in beats-audio
  - products.master_url restored and backfilled
  - column-level access to products.master_path restored (to avoid SELECT * failures)
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Buckets: restore legacy beats-audio behavior
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN
    RAISE NOTICE 'Schema storage not found; skipping bucket rollback.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'beats-audio') THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES (
      'beats-audio',
      'Producer audio (public previews)',
      true,
      52428800,
      '{audio/mpeg,audio/mp3,audio/wav,audio/x-wav,audio/wave}'
    );
  ELSE
    UPDATE storage.buckets
    SET
      public = true,
      file_size_limit = 52428800,
      allowed_mime_types = '{audio/mpeg,audio/mp3,audio/wav,audio/x-wav,audio/wave}'
    WHERE id = 'beats-audio';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2) storage.objects policies: restore legacy read access
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  objects_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) INTO objects_exists;

  IF NOT objects_exists THEN
    RAISE NOTICE 'storage.objects table not found; skipping policy rollback.';
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Authenticated users can read beats audio'
  ) THEN
    DROP POLICY IF EXISTS "Authenticated users can read beats audio" ON storage.objects;
    CREATE POLICY "Authenticated users can read beats audio"
      ON storage.objects
      FOR SELECT
      TO authenticated
      USING (bucket_id = 'beats-audio');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'Producers can read their audio'
  ) THEN
    DROP POLICY IF EXISTS "Producers can read their audio" ON storage.objects;
    CREATE POLICY "Producers can read their audio"
      ON storage.objects
      FOR SELECT
      TO authenticated
      USING (
        bucket_id = 'beats-audio'
        AND auth.uid() = owner
        AND public.is_active_producer(auth.uid())
      );
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 3) Products: restore legacy master_url and compatibility with SELECT *
-- ---------------------------------------------------------------------------
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS master_url text;

DO $$
DECLARE
  has_master_path boolean;
  has_watermarked_path boolean;
  has_preview_url boolean;
  has_exclusive_preview_url boolean;
  master_url_coalesce_args text := 'master_url';
  preview_url_coalesce_args text := 'preview_url';
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'master_path'
  ) INTO has_master_path;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'watermarked_path'
  ) INTO has_watermarked_path;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'preview_url'
  ) INTO has_preview_url;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'exclusive_preview_url'
  ) INTO has_exclusive_preview_url;

  IF has_master_path THEN
    master_url_coalesce_args := master_url_coalesce_args || ', master_path';
  END IF;
  IF has_watermarked_path THEN
    master_url_coalesce_args := master_url_coalesce_args || ', watermarked_path';
  END IF;
  IF has_preview_url THEN
    master_url_coalesce_args := master_url_coalesce_args || ', preview_url';
  END IF;
  IF has_exclusive_preview_url THEN
    master_url_coalesce_args := master_url_coalesce_args || ', exclusive_preview_url';
  END IF;

  EXECUTE format(
    'UPDATE public.products SET master_url = COALESCE(%s) WHERE master_url IS NULL',
    master_url_coalesce_args
  );

  IF has_preview_url THEN
    IF has_watermarked_path THEN
      preview_url_coalesce_args := preview_url_coalesce_args || ', watermarked_path';
    END IF;
    preview_url_coalesce_args := preview_url_coalesce_args || ', master_url';

    EXECUTE format(
      'UPDATE public.products SET preview_url = COALESCE(%s) WHERE preview_url IS NULL',
      preview_url_coalesce_args
    );
  END IF;
END
$$;

-- If master_path exists and was revoked in 023/024, restore visibility for client roles
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'products'
      AND column_name = 'master_path'
  ) THEN
    GRANT SELECT(master_path) ON TABLE public.products TO PUBLIC;
    GRANT SELECT(master_path) ON TABLE public.products TO anon;
    GRANT SELECT(master_path) ON TABLE public.products TO authenticated;
  END IF;
END
$$;

GRANT SELECT(master_url) ON TABLE public.products TO PUBLIC;
GRANT SELECT(master_url) ON TABLE public.products TO anon;
GRANT SELECT(master_url) ON TABLE public.products TO authenticated;

COMMIT;
