/*
  # Add admin pilotage v2 RPCs

  Additive migration:
  - public.get_admin_pilotage_deltas()
  - public.get_admin_metrics_timeseries()
  - public.get_admin_business_metrics()
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.get_admin_pilotage_deltas()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_users_current bigint := 0;
  v_users_previous bigint := 0;
  v_revenue_current bigint := 0;
  v_revenue_previous bigint := 0;
  v_beats_current bigint := 0;
  v_beats_previous bigint := 0;
  v_users_growth_30d_pct numeric(12,2) := NULL;
  v_revenue_growth_30d_pct numeric(12,2) := NULL;
  v_beats_growth_30d_pct numeric(12,2) := NULL;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin(v_actor) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_users_current
  FROM public.user_profiles
  WHERE created_at >= now() - interval '30 days';

  SELECT COUNT(*)::bigint
  INTO v_users_previous
  FROM public.user_profiles
  WHERE created_at >= now() - interval '60 days'
    AND created_at < now() - interval '30 days';

  SELECT COALESCE(SUM(amount), 0)::bigint
  INTO v_revenue_current
  FROM public.purchases
  WHERE status = 'completed'
    AND created_at >= now() - interval '30 days';

  SELECT COALESCE(SUM(amount), 0)::bigint
  INTO v_revenue_previous
  FROM public.purchases
  WHERE status = 'completed'
    AND created_at >= now() - interval '60 days'
    AND created_at < now() - interval '30 days';

  SELECT COUNT(*)::bigint
  INTO v_beats_current
  FROM public.products
  WHERE product_type = 'beat'
    AND is_published = true
    AND deleted_at IS NULL
    AND created_at >= now() - interval '30 days';

  SELECT COUNT(*)::bigint
  INTO v_beats_previous
  FROM public.products
  WHERE product_type = 'beat'
    AND is_published = true
    AND deleted_at IS NULL
    AND created_at >= now() - interval '60 days'
    AND created_at < now() - interval '30 days';

  IF v_users_previous > 0 THEN
    v_users_growth_30d_pct := ROUND(
      ((v_users_current::numeric - v_users_previous::numeric) / v_users_previous::numeric) * 100.0,
      2
    );
  END IF;

  IF v_revenue_previous > 0 THEN
    v_revenue_growth_30d_pct := ROUND(
      ((v_revenue_current::numeric - v_revenue_previous::numeric) / v_revenue_previous::numeric) * 100.0,
      2
    );
  END IF;

  IF v_beats_previous > 0 THEN
    v_beats_growth_30d_pct := ROUND(
      ((v_beats_current::numeric - v_beats_previous::numeric) / v_beats_previous::numeric) * 100.0,
      2
    );
  END IF;

  RETURN jsonb_build_object(
    'users_growth_30d_pct', v_users_growth_30d_pct,
    'revenue_growth_30d_pct', v_revenue_growth_30d_pct,
    'beats_growth_30d_pct', v_beats_growth_30d_pct
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_metrics_timeseries()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_users_30d jsonb := '[]'::jsonb;
  v_revenue_30d jsonb := '[]'::jsonb;
  v_beats_30d jsonb := '[]'::jsonb;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin(v_actor) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH days AS (
    SELECT generate_series(
      (current_date - interval '29 days')::date,
      current_date::date,
      interval '1 day'
    )::date AS day
  ),
  users_daily AS (
    SELECT date_trunc('day', created_at)::date AS day, COUNT(*)::bigint AS value
    FROM public.user_profiles
    WHERE created_at >= (current_date - interval '29 days')
    GROUP BY 1
  ),
  revenue_daily AS (
    SELECT date_trunc('day', created_at)::date AS day, COALESCE(SUM(amount), 0)::bigint AS value
    FROM public.purchases
    WHERE status = 'completed'
      AND created_at >= (current_date - interval '29 days')
    GROUP BY 1
  ),
  beats_daily AS (
    SELECT date_trunc('day', created_at)::date AS day, COUNT(*)::bigint AS value
    FROM public.products
    WHERE product_type = 'beat'
      AND is_published = true
      AND deleted_at IS NULL
      AND created_at >= (current_date - interval '29 days')
    GROUP BY 1
  )
  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'date', to_char(d.day, 'YYYY-MM-DD'),
          'value', COALESCE(u.value, 0)
        )
        ORDER BY d.day
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'date', to_char(d.day, 'YYYY-MM-DD'),
          'value', COALESCE(r.value, 0)
        )
        ORDER BY d.day
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'date', to_char(d.day, 'YYYY-MM-DD'),
          'value', COALESCE(b.value, 0)
        )
        ORDER BY d.day
      ),
      '[]'::jsonb
    )
  INTO v_users_30d, v_revenue_30d, v_beats_30d
  FROM days d
  LEFT JOIN users_daily u ON u.day = d.day
  LEFT JOIN revenue_daily r ON r.day = d.day
  LEFT JOIN beats_daily b ON b.day = d.day;

  RETURN jsonb_build_object(
    'users_30d', v_users_30d,
    'revenue_30d', v_revenue_30d,
    'beats_30d', v_beats_30d
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_business_metrics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_total_users bigint := 0;
  v_active_producers bigint := 0;
  v_active_producers_with_publication bigint := 0;
  v_published_beats bigint := 0;
  v_completed_purchases bigint := 0;
  v_monthly_revenue_cents bigint := 0;
  v_producer_publication_rate_pct numeric(12,2) := 0;
  v_beats_conversion_rate_pct numeric(12,2) := 0;
  v_arpu_cents bigint := 0;
  v_active_producer_ratio_pct numeric(12,2) := 0;
BEGIN
  IF v_actor IS NULL OR NOT public.is_admin(v_actor) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_total_users
  FROM public.user_profiles;

  SELECT COUNT(*)::bigint
  INTO v_active_producers
  FROM public.user_profiles
  WHERE is_producer_active = true;

  SELECT COUNT(DISTINCT p.producer_id)::bigint
  INTO v_active_producers_with_publication
  FROM public.products p
  JOIN public.user_profiles up ON up.id = p.producer_id
  WHERE up.is_producer_active = true
    AND p.product_type = 'beat'
    AND p.is_published = true
    AND p.deleted_at IS NULL;

  SELECT COUNT(*)::bigint
  INTO v_published_beats
  FROM public.products
  WHERE product_type = 'beat'
    AND is_published = true
    AND deleted_at IS NULL;

  SELECT COUNT(*)::bigint
  INTO v_completed_purchases
  FROM public.purchases
  WHERE status = 'completed';

  SELECT COALESCE(SUM(amount), 0)::bigint
  INTO v_monthly_revenue_cents
  FROM public.purchases
  WHERE status = 'completed'
    AND created_at >= date_trunc('month', now())
    AND created_at < date_trunc('month', now()) + interval '1 month';

  IF v_active_producers > 0 THEN
    v_producer_publication_rate_pct := ROUND(
      (v_active_producers_with_publication::numeric / v_active_producers::numeric) * 100.0,
      2
    );
  END IF;

  IF v_published_beats > 0 THEN
    v_beats_conversion_rate_pct := ROUND(
      (v_completed_purchases::numeric / v_published_beats::numeric) * 100.0,
      2
    );
  END IF;

  IF v_total_users > 0 THEN
    v_arpu_cents := ROUND(v_monthly_revenue_cents::numeric / v_total_users::numeric)::bigint;
    v_active_producer_ratio_pct := ROUND(
      (v_active_producers::numeric / v_total_users::numeric) * 100.0,
      2
    );
  END IF;

  RETURN jsonb_build_object(
    'producer_publication_rate_pct', v_producer_publication_rate_pct,
    'beats_conversion_rate_pct', v_beats_conversion_rate_pct,
    'arpu_cents', v_arpu_cents,
    'active_producer_ratio_pct', v_active_producer_ratio_pct
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_admin_pilotage_deltas() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_admin_pilotage_deltas() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_admin_pilotage_deltas() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_pilotage_deltas() TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_admin_metrics_timeseries() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_admin_metrics_timeseries() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_admin_metrics_timeseries() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_metrics_timeseries() TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_admin_business_metrics() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_admin_business_metrics() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_admin_business_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_business_metrics() TO service_role;

COMMIT;
