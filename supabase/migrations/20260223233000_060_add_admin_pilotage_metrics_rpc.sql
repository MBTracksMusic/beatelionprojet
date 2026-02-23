/*
  # Add admin pilotage metrics RPC

  Additive migration:
  - Adds public.get_admin_pilotage_metrics() for admin-only KPI aggregation
  - Reuses public.is_admin(uuid) when available
  - Keeps existing RLS and policies unchanged
*/

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.is_admin(uuid)') IS NULL THEN
    CREATE OR REPLACE FUNCTION public.is_admin(p_user_id uuid DEFAULT auth.uid())
    RETURNS boolean
    LANGUAGE plpgsql
    SECURITY INVOKER
    SET search_path = public, pg_temp
    AS $func$
    DECLARE
      v_uid uuid := COALESCE(p_user_id, auth.uid());
    BEGIN
      IF v_uid IS NULL THEN
        RETURN false;
      END IF;

      RETURN EXISTS (
        SELECT 1
        FROM public.user_profiles up
        WHERE up.id = v_uid
          AND up.role = 'admin'
      );
    END;
    $func$;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.get_admin_pilotage_metrics()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_total_users bigint := 0;
  v_active_producers bigint := 0;
  v_published_beats bigint := 0;
  v_active_battles bigint := 0;
  v_monthly_revenue_beats_cents bigint := 0;
  v_subscription_mrr_estimate_cents bigint := 0;
  v_confirmed_signup_rate_pct numeric(12,2) := 0;
  v_user_growth_30d_pct numeric(12,2) := NULL;
  v_current_30d_users bigint := 0;
  v_previous_30d_users bigint := 0;
  v_month_start timestamptz := date_trunc('month', now());
  v_month_end timestamptz := date_trunc('month', now()) + interval '1 month';
  v_active_subscription_count bigint := 0;
  v_plan_amount_cents bigint := 0;
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

  SELECT COUNT(*)::bigint
  INTO v_published_beats
  FROM public.products
  WHERE product_type = 'beat'
    AND is_published = true
    AND deleted_at IS NULL;

  SELECT COUNT(*)::bigint
  INTO v_active_battles
  FROM public.battles
  WHERE status IN ('active', 'voting');

  SELECT COALESCE(SUM(p.amount), 0)::bigint
  INTO v_monthly_revenue_beats_cents
  FROM public.purchases p
  WHERE p.status = 'completed'
    AND p.created_at >= v_month_start
    AND p.created_at < v_month_end;

  IF to_regclass('public.producer_subscriptions') IS NOT NULL THEN
    SELECT COUNT(*)::bigint
    INTO v_active_subscription_count
    FROM public.producer_subscriptions ps
    WHERE ps.is_producer_active = true
      AND ps.current_period_end > now();
  END IF;

  IF to_regclass('public.producer_plan_config') IS NOT NULL THEN
    SELECT COALESCE(MAX(ppc.amount_cents), 0)::bigint
    INTO v_plan_amount_cents
    FROM public.producer_plan_config ppc;
  ELSE
    -- Fallback: if plan config is absent, keep MRR estimate at 0 by design.
    v_plan_amount_cents := 0;
  END IF;

  v_subscription_mrr_estimate_cents := v_active_subscription_count * v_plan_amount_cents;

  IF v_total_users > 0 THEN
    SELECT ROUND(
      100.0 * SUM(CASE WHEN COALESCE(up.is_confirmed, false) THEN 1 ELSE 0 END)::numeric
      / v_total_users::numeric,
      2
    )
    INTO v_confirmed_signup_rate_pct
    FROM public.user_profiles up;
  END IF;

  SELECT COUNT(*)::bigint
  INTO v_current_30d_users
  FROM public.user_profiles up
  WHERE up.created_at >= now() - interval '30 days';

  SELECT COUNT(*)::bigint
  INTO v_previous_30d_users
  FROM public.user_profiles up
  WHERE up.created_at >= now() - interval '60 days'
    AND up.created_at < now() - interval '30 days';

  IF v_previous_30d_users > 0 THEN
    v_user_growth_30d_pct := ROUND(
      ((v_current_30d_users::numeric - v_previous_30d_users::numeric) / v_previous_30d_users::numeric) * 100.0,
      2
    );
  ELSE
    v_user_growth_30d_pct := NULL;
  END IF;

  RETURN jsonb_build_object(
    'total_users', v_total_users,
    'active_producers', v_active_producers,
    'published_beats', v_published_beats,
    'active_battles', v_active_battles,
    'monthly_revenue_beats_cents', v_monthly_revenue_beats_cents,
    'subscription_mrr_estimate_cents', v_subscription_mrr_estimate_cents,
    'confirmed_signup_rate_pct', v_confirmed_signup_rate_pct,
    'user_growth_30d_pct', v_user_growth_30d_pct
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_admin_pilotage_metrics() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_admin_pilotage_metrics() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_admin_pilotage_metrics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_pilotage_metrics() TO service_role;

COMMIT;
