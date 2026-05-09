-- supabase/migrations/20260510000000_founding_producer_trial_system.sql

-- ─── 1. Fonction helper : détecte un trial Founding Producer actif ──────────
-- Utilisée par is_active_producer() et les policies SELECT du catalogue.
-- Fallback : interval '3 months' si aucune campagne liée (producer_campaign_type IS NULL).
CREATE OR REPLACE FUNCTION private.is_in_active_trial(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
    WHERE up.id = uid
      AND up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND now() < up.founding_trial_start + COALESCE(pc.trial_duration, interval '3 months')
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  );
$$;

-- ─── 2. Mettre à jour is_active_producer() pour inclure le trial ─────────────
-- Toutes les storage policies (beats-masters, beats-covers, beats-audio) appellent
-- is_active_producer() — elles bénéficient automatiquement de ce changement.
CREATE OR REPLACE FUNCTION public.is_active_producer(p_user uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  uid uuid := COALESCE(p_user, auth.uid());
BEGIN
  IF uid IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = uid AND up.is_producer_active = true
  )
  OR private.is_in_active_trial(uid);
END;
$$;

-- ─── 3. Policy INSERT products : autoriser les producteurs en trial ───────────
DROP POLICY IF EXISTS "Active producers can create products" ON public.products;
CREATE POLICY "Active producers can create products"
ON public.products
FOR INSERT
TO authenticated
WITH CHECK (
  producer_id = auth.uid()
  AND is_current_user_active(auth.uid())
  AND is_active_producer(auth.uid())
  AND (
    COALESCE(is_elite, false) = false
    OR EXISTS (
      SELECT 1 FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.account_type = 'elite_producer'
        AND is_active_producer(up.id)
        AND COALESCE(up.is_deleted, false) = false
        AND up.deleted_at IS NULL
    )
  )
  AND (
    NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
    OR private.can_publish_beat(auth.uid(), NULL::uuid)
  )
);

-- ─── 4. Policy SELECT catalogue public : masquer les beats des trials expirés ─
-- "Public read products simple" (qual=true pour anon) est trop permissive.
-- On la supprime — "Public can view published products" (roles PUBLIC) couvre anon.
DROP POLICY IF EXISTS "Public read products simple" ON public.products;

DROP POLICY IF EXISTS "Public can view published products" ON public.products;
CREATE POLICY "Public can view published products"
ON public.products
FOR SELECT
TO PUBLIC
USING (
  is_published = true
  AND is_active_producer(producer_id)
);

-- ─── 5. RPC get_my_trial_status() ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_trial_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH trial_info AS (
    SELECT
      up.is_producer_active,
      up.is_founding_producer,
      up.founding_trial_start,
      COALESCE(pc.trial_duration, interval '3 months') AS trial_duration
    FROM public.user_profiles up
    LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
    WHERE up.id = auth.uid()
  )
  SELECT CASE
    WHEN ti.is_producer_active = true
      THEN jsonb_build_object('status', 'subscribed')
    WHEN ti.is_founding_producer = true AND ti.founding_trial_start IS NOT NULL THEN
      CASE
        WHEN now() >= ti.founding_trial_start + ti.trial_duration
          THEN jsonb_build_object('status', 'expired')
        WHEN now() >= ti.founding_trial_start + ti.trial_duration - interval '7 days'
          THEN jsonb_build_object(
            'status', 'expiring_soon',
            'days_remaining', GREATEST(1, EXTRACT(DAY FROM (ti.founding_trial_start + ti.trial_duration - now()))::int)
          )
        ELSE jsonb_build_object(
          'status', 'active',
          'days_remaining', EXTRACT(DAY FROM (ti.founding_trial_start + ti.trial_duration - now()))::int
        )
      END
    ELSE jsonb_build_object('status', 'none')
  END
  FROM trial_info ti;
$$;

REVOKE ALL ON FUNCTION public.get_my_trial_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_trial_status() TO authenticated;
