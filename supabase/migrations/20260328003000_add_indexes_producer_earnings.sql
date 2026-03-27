BEGIN;

CREATE INDEX IF NOT EXISTS idx_purchases_product_status
ON public.purchases(product_id, status);

CREATE INDEX IF NOT EXISTS idx_products_producer_id
ON public.products(producer_id);

COMMIT;
