BEGIN;

ALTER VIEW public.producer_revenue_view
  SET (security_invoker = true);

COMMIT;
