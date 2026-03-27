BEGIN;

DROP POLICY IF EXISTS "Authenticated users can view products" ON public.products;

CREATE POLICY "Authenticated users can view products"
  ON public.products
  FOR SELECT
  TO authenticated
  USING (
    is_published = true
    OR producer_id = auth.uid()
    OR EXISTS (
      SELECT 1
      FROM public.cart_items ci
      WHERE ci.user_id = auth.uid()
        AND ci.product_id = products.id
    )
    OR EXISTS (
      SELECT 1
      FROM public.wishlists w
      WHERE w.user_id = auth.uid()
        AND w.product_id = products.id
    )
    OR EXISTS (
      SELECT 1
      FROM public.purchases pur
      WHERE pur.user_id = auth.uid()
        AND pur.product_id = products.id
    )
  );

CREATE TABLE IF NOT EXISTS public.security_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL,
  user_id uuid NULL REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_security_events_type
  ON public.security_events(type);

CREATE INDEX IF NOT EXISTS idx_security_events_created_at_desc
  ON public.security_events(created_at DESC);

ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.security_events FROM PUBLIC;
REVOKE ALL ON TABLE public.security_events FROM anon;
REVOKE ALL ON TABLE public.security_events FROM authenticated;

GRANT SELECT ON TABLE public.security_events TO authenticated;
GRANT SELECT ON TABLE public.security_events TO service_role;

DROP POLICY IF EXISTS "Admins can view security events" ON public.security_events;

CREATE POLICY "Admins can view security events"
  ON public.security_events
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

CREATE OR REPLACE FUNCTION public.log_security_event(
  p_type text,
  p_user_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_id uuid;
BEGIN
  IF p_type IS NULL OR btrim(p_type) = '' THEN
    RAISE EXCEPTION 'security_event_type_required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.security_events (
    type,
    user_id,
    metadata
  ) VALUES (
    p_type,
    p_user_id,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.log_security_event(text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.log_security_event(text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.log_security_event(text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.log_security_event(text, uuid, jsonb) TO service_role;

CREATE OR REPLACE VIEW public.fallback_payout_monitoring AS
SELECT
  fpa.purchase_id,
  fpa.producer_id,
  fpa.username,
  fpa.email,
  fpa.payout_amount_eur AS amount_owed_eur,
  fpa.days_pending,
  CASE
    WHEN fpa.urgency_level LIKE 'CRITIQUE%' THEN 'CRITICAL'
    WHEN fpa.urgency_level LIKE 'WARNING%' THEN 'WARNING'
    ELSE 'OK'
  END AS urgency
FROM public.fallback_payout_alerts fpa;

REVOKE ALL ON TABLE public.fallback_payout_monitoring FROM PUBLIC;
REVOKE ALL ON TABLE public.fallback_payout_monitoring FROM anon;
REVOKE ALL ON TABLE public.fallback_payout_monitoring FROM authenticated;
GRANT SELECT ON TABLE public.fallback_payout_monitoring TO service_role;

COMMIT;
