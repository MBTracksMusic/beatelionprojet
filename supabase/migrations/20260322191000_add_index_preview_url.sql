BEGIN;

CREATE INDEX IF NOT EXISTS idx_products_preview_url
ON public.products (preview_url);

COMMIT;
