/*
  # Fix Security Advisor – All 9 Security Definer Views + Storage Broad-Select Policies

  ## Context
  Supabase Security Advisor flags nine views as SECURITY DEFINER (errors) and four
  storage buckets as having broad SELECT policies that allow file enumeration (warnings).

  All previous attempts to fix this were reset by pg_dump remote_schema migrations that
  do not preserve the `security_invoker = true` flag on views.

  ## Visitor / anon access model (as designed)
  Visitors (anon) can:
  - Browse the public product catalog (published, active, non-early-access beats)
  - See producer public profiles (active producers only)
  - See open battle campaigns (applications_open, selection_locked, launched)
  - Read watermarked audio previews and cover images by URL

  Visitors CANNOT:
  - List all files in storage buckets (file enumeration)
  - See any purchase details (who bought what, amounts)
  - See producer revenue, payout data, or admin financial views

  ## Changes

  ### 1. New RLS policies on underlying tables

  purchases:
  - "Producers can view purchases of their products"  → enables producer_revenue_view
    and producer_stats to work with security_invoker for authenticated producers
  - "Public can view completed purchase product ids"  → allows anon to count sales per
    product (only product_id + status columns granted) for producer_beats_ranked ranks

  user_profiles:
  - "Admins can view all user profiles"               → enables admin_revenue_breakdown
    and fallback_payout_alerts (which join user_profiles for email/username) to work
    with security_invoker for admin callers

  admin_battle_campaigns:
  - "Public can read open battle campaigns"           → enables admin_battle_campaigns_public
    to be accessible to anon/authenticated via security_invoker

  ### 2. Column-level grant on purchases for anon
  Only (product_id, status) granted to anon — sufficient to count completed sales
  per product without exposing buyer identity, amounts, or Stripe references.

  ### 3. security_invoker = true on all 9 views
  - producer_revenue_view
  - products_public
  - producer_beats_ranked
  - producer_stats
  - public_products
  - fallback_payout_alerts
  - public_catalog_products
  - admin_revenue_breakdown
  - admin_battle_campaigns_public

  ### 4. Storage broad-SELECT policies tightened
  Replace `USING (bucket_id = '<bucket>')` (allows full enumeration) with path-restricted
  policies so callers can only list their own folder. Files remain accessible by public URL
  because the buckets are marked public=true (URL access does not require an RLS policy).

  Buckets fixed:
  - avatars                       : authenticated-only listing of own folder
  - beats-covers                  : authenticated-only listing of own folder
  - beats-watermarked             : authenticated-only listing of own folder
  - battle-campaign-images        : anon + authenticated listing restricted to campaigns/

  ### 5. NOT fixed here
  - Leaked Password Protection Disabled: must be enabled in the Supabase Auth dashboard
    (Authentication → Settings → "Enable leaked password protection"). No SQL equivalent.
  - pg_net Extension in Public: Supabase-managed infrastructure; moving it would break
    internal Supabase edge network plumbing. Leave as-is.
*/

BEGIN;

-- ============================================================================
-- 1. purchases: allow producers to see purchases of their products
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'purchases'
      AND policyname = 'Producers can view purchases of their products'
  ) THEN
    CREATE POLICY "Producers can view purchases of their products"
      ON public.purchases
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM public.products pr
          WHERE pr.id          = purchases.product_id
            AND pr.producer_id = auth.uid()
        )
      );
  END IF;
END;
$$;

-- ============================================================================
-- 2. purchases: grant anon access to (product_id, status) only for ranking counts
--    This lets producer_beats_ranked aggregate sales counts without exposing
--    buyer identity, Stripe references, or financial amounts.
-- ============================================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'purchases'
  ) THEN
    -- Column-level grant: anon can only see product_id and status
    GRANT SELECT (product_id, status) ON TABLE public.purchases TO anon;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'purchases'
      AND policyname = 'Public can view completed purchase product ids'
  ) THEN
    CREATE POLICY "Public can view completed purchase product ids"
      ON public.purchases
      FOR SELECT
      TO anon
      USING (status = 'completed'::public.purchase_status);
  END IF;
END;
$$;

-- ============================================================================
-- 3. user_profiles: allow admins to read all profiles (incl. email)
--    Needed by admin_revenue_breakdown and fallback_payout_alerts which join
--    user_profiles to expose buyer_email / producer_email to admins.
--    authenticated already has table-level SELECT (migration 081); this policy
--    opens the admin rows that the existing "Owner can select own profile" policy
--    would otherwise hide.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'user_profiles'
      AND policyname = 'Admins can view all user profiles'
  ) THEN
    CREATE POLICY "Admins can view all user profiles"
      ON public.user_profiles
      FOR SELECT
      TO authenticated
      USING (public.is_admin(auth.uid()));
  END IF;
END;
$$;

-- ============================================================================
-- 4. admin_battle_campaigns: allow public read of open campaigns
--    The "Anyone can read admin battle campaigns" policy was dropped in
--    migration 147_harden. Restore a scoped version limited to safe statuses
--    so that admin_battle_campaigns_public (security_invoker) returns data for
--    anon visitors.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'admin_battle_campaigns'
      AND policyname = 'Public can read open battle campaigns'
  ) THEN
    CREATE POLICY "Public can read open battle campaigns"
      ON public.admin_battle_campaigns
      FOR SELECT
      TO anon, authenticated
      USING (
        status IN (
          'applications_open'::public.admin_battle_campaign_status,
          'selection_locked'::public.admin_battle_campaign_status,
          'launched'::public.admin_battle_campaign_status
        )
      );
  END IF;
END;
$$;

-- ============================================================================
-- 5. Set security_invoker = true on all 9 Security Definer views
--
--    Order matters: public_catalog_products depends on producer_beats_ranked,
--    so ranked must be patched first (PostgreSQL resolves at query time, but
--    ALTER VIEW is safest in dependency order).
-- ============================================================================

-- 5a. Producer-specific views
ALTER VIEW public.producer_beats_ranked       SET (security_invoker = true);
ALTER VIEW public.producer_revenue_view       SET (security_invoker = true);
ALTER VIEW public.producer_stats              SET (security_invoker = true);

-- 5b. Public catalog views (depend on producer_beats_ranked above)
ALTER VIEW public.public_catalog_products     SET (security_invoker = true);
ALTER VIEW public.public_products             SET (security_invoker = true);
ALTER VIEW public.products_public             SET (security_invoker = true);

-- 5c. Admin-only views
ALTER VIEW public.admin_revenue_breakdown     SET (security_invoker = true);
ALTER VIEW public.fallback_payout_alerts      SET (security_invoker = true);

-- 5d. Public campaign view
ALTER VIEW public.admin_battle_campaigns_public SET (security_invoker = true);

-- ============================================================================
-- 6. Storage: replace broad enumeration-allowing SELECT policies
--    Buckets remain public=true, so files are still accessible by direct URL.
--    The policies below only affect listing via the storage API.
-- ============================================================================
DO $$
DECLARE
  objects_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'storage' AND table_name = 'objects'
  ) INTO objects_exists;

  IF NOT objects_exists THEN
    RAISE NOTICE 'storage.objects not found; skipping storage policy hardening.';
    RETURN;
  END IF;

  -- ------------------------------------------------------------------
  -- avatars bucket: users can only list their own folder
  -- ------------------------------------------------------------------
  DROP POLICY IF EXISTS "Anyone can view avatars" ON storage.objects;

  CREATE POLICY "Authenticated users can list own avatars"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'avatars'
      AND name LIKE auth.uid()::text || '/%'
    );

  -- ------------------------------------------------------------------
  -- beats-covers bucket: producers can only list their own folder
  -- ------------------------------------------------------------------
  DROP POLICY IF EXISTS "Anyone can view covers" ON storage.objects;

  CREATE POLICY "Authenticated users can list own covers"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'beats-covers'
      AND name LIKE auth.uid()::text || '/%'
    );

  -- ------------------------------------------------------------------
  -- beats-watermarked bucket: producers can only list their own folder
  -- ------------------------------------------------------------------
  DROP POLICY IF EXISTS "Public can read watermarked audio" ON storage.objects;

  CREATE POLICY "Authenticated users can list own watermarked audio"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'beats-watermarked'
      AND name LIKE auth.uid()::text || '/%'
    );

  -- ------------------------------------------------------------------
  -- battle-campaign-images bucket: restrict listing to campaigns/ path
  -- (kept accessible to anon because campaign images are genuinely public)
  -- ------------------------------------------------------------------
  DROP POLICY IF EXISTS "Anyone can view battle campaign images" ON storage.objects;

  CREATE POLICY "Public can view battle campaign images"
    ON storage.objects
    FOR SELECT
    TO anon, authenticated
    USING (
      bucket_id = 'battle-campaign-images'
      AND name LIKE 'campaigns/%'
    );

END;
$$;

COMMIT;
