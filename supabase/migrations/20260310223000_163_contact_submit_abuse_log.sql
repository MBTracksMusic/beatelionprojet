/*
  # Contact submit abuse log

  Security hardening for public contact endpoint:
  - stores accepted/rejected attempts for durable abuse controls
  - supports per-IP / per-email rate limits and duplicate replay detection
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.contact_submit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address text,
  email_hash text,
  submission_hash text,
  user_agent text,
  subject text,
  status text NOT NULL CHECK (status IN ('accepted', 'rejected')),
  reason text
);

-- Time-window queries
CREATE INDEX IF NOT EXISTS idx_contact_submit_log_created_at
  ON public.contact_submit_log (created_at DESC);

-- Per-IP rate limiting windows
CREATE INDEX IF NOT EXISTS idx_contact_submit_log_ip_created_at
  ON public.contact_submit_log (ip_address, created_at DESC)
  WHERE ip_address IS NOT NULL;

-- Per-email rate limiting windows
CREATE INDEX IF NOT EXISTS idx_contact_submit_log_email_created_at
  ON public.contact_submit_log (email_hash, created_at DESC)
  WHERE email_hash IS NOT NULL;

-- Duplicate/replay detection windows
CREATE INDEX IF NOT EXISTS idx_contact_submit_log_submission_created_at
  ON public.contact_submit_log (submission_hash, created_at DESC)
  WHERE submission_hash IS NOT NULL;

ALTER TABLE public.contact_submit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can read contact submit logs" ON public.contact_submit_log;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'contact_submit_log'
      AND policyname = 'Admins can read contact submit logs'
  ) THEN
    CREATE POLICY "Admins can read contact submit logs"
    ON public.contact_submit_log
    FOR SELECT
    TO authenticated
    USING (public.is_admin(auth.uid()));
  END IF;
END
$$;

COMMIT;
