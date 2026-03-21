-- Create public.waitlist for maintenance-page email capture.
-- Access is intended through the join-waitlist Edge Function.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS public.waitlist (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS waitlist_email_key
  ON public.waitlist (email);

CREATE INDEX IF NOT EXISTS idx_waitlist_created_at_desc
  ON public.waitlist (created_at DESC);

ALTER TABLE public.waitlist ENABLE ROW LEVEL SECURITY;
