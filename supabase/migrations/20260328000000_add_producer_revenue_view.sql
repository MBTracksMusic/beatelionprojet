BEGIN;

CREATE OR REPLACE VIEW public.producer_revenue_view AS
SELECT
  p.id,
  p.created_at,
  p.product_id,
  pr.title AS product_title,
  p.purchase_source,
  ROUND(COALESCE(p.producer_share_cents_snapshot, 0)::numeric / 100.0, 2) AS amount_earned_eur,
  COALESCE(p.metadata->>'payout_status', 'pending') AS payout_status,
  COALESCE(p.metadata->>'payout_mode', 'stripe_connect') AS payout_mode,
  CASE
    WHEN p.metadata->>'payout_processed_at' IS NOT NULL
    THEN (p.metadata->>'payout_processed_at')::timestamptz
    ELSE NULL
  END AS payout_processed_at
FROM public.purchases p
JOIN public.products pr ON pr.id = p.product_id
WHERE pr.producer_id = auth.uid()
  AND p.status = 'completed'
ORDER BY p.created_at DESC;

GRANT SELECT ON TABLE public.producer_revenue_view TO authenticated;
GRANT SELECT ON TABLE public.producer_revenue_view TO service_role;

COMMENT ON VIEW public.producer_revenue_view IS
  'Read-only view for producers to see their revenue. Shows completed purchases with payout status.';

COMMIT;
