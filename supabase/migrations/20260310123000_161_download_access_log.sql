/*
  # Secure master download access log

  - Stores successful `get-master-url` grants only.
  - Supports server-side anti-scraping windows:
    - per user + product in last minute
    - per user global in last ten minutes
*/

BEGIN;

-- Successful secure download grants used by get-master-url anti-abuse checks.
CREATE TABLE IF NOT EXISTS public.download_access_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  product_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address text NULL,
  user_agent text NULL
);

CREATE INDEX IF NOT EXISTS idx_download_access_log_user_created_at
  ON public.download_access_log (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_download_access_log_user_product_created_at
  ON public.download_access_log (user_id, product_id, created_at DESC);

ALTER TABLE public.download_access_log ENABLE ROW LEVEL SECURITY;

COMMIT;
