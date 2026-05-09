-- Fix I1: include trial status in public_producer_profiles is_producer_active
-- private._view_public_producer_profiles() is SECURITY DEFINER with search_path
-- including 'private', so it can safely call private.is_in_active_trial(up.id).
-- Trial producers have no Stripe subscription row and is_producer_active = false,
-- so they fell to the ELSE branch and were hidden from the catalog. The fix adds
-- OR private.is_in_active_trial(up.id) to that ELSE branch.
CREATE OR REPLACE FUNCTION private._view_public_producer_profiles()
RETURNS TABLE(
  user_id uuid, username text, avatar_url text,
  producer_tier producer_tier_type, bio text, social_links jsonb,
  xp bigint, level integer, rank_tier text, reputation_score numeric,
  created_at timestamptz, updated_at timestamptz,
  raw_username text, is_deleted boolean, is_producer_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
  SELECT
    up.id AS user_id,
    get_public_profile_label(up.*) AS username,
    CASE
      WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL::text
      ELSE up.avatar_url
    END AS avatar_url,
    up.producer_tier,
    CASE
      WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN NULL::text
      ELSE up.bio
    END AS bio,
    CASE
      WHEN COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL THEN '{}'::jsonb
      ELSE COALESCE(up.social_links, '{}'::jsonb)
    END AS social_links,
    COALESCE(ur.xp, 0::bigint) AS xp,
    COALESCE(ur.level, 1) AS level,
    COALESCE(ur.rank_tier, 'bronze'::text) AS rank_tier,
    COALESCE(ur.reputation_score, 0::numeric) AS reputation_score,
    up.created_at,
    up.updated_at,
    up.username AS raw_username,
    COALESCE(up.is_deleted, false) = true OR up.deleted_at IS NOT NULL AS is_deleted,
    CASE
      WHEN EXISTS (
        SELECT 1 FROM producer_subscriptions ps_any
        WHERE ps_any.user_id = up.id
      )
      THEN EXISTS (
        SELECT 1 FROM producer_subscriptions ps
        WHERE ps.user_id = up.id
          AND COALESCE(ps.is_producer_active, false) = true
          AND ps.subscription_status = ANY (ARRAY['active'::text, 'trialing'::text])
          AND ps.current_period_end > now()
      )
      -- No Stripe subscription: check direct flag OR active founding trial
      ELSE (COALESCE(up.is_producer_active, false) OR private.is_in_active_trial(up.id))
    END AS is_producer_active
  FROM user_profiles up
  LEFT JOIN user_reputation ur ON ur.user_id = up.id
  WHERE NULLIF(btrim(COALESCE(up.username, ''::text)), ''::text) IS NOT NULL
    AND up.role = 'producer'::user_role;
$$;

-- Fix I2: UPDATE policy must use is_active_producer() so trial producers
-- can update their products during the upload flow (UploadBeat.tsx does
-- multiple UPDATEs after the initial INSERT to set master_path, cover_url etc.).
-- The old policy checked up.is_producer_active = true directly, bypassing the
-- trial check that is_active_producer() already performs via is_in_active_trial().
-- We also fix the two elite-producer EXISTS subqueries in WITH CHECK that had
-- the same direct is_producer_active = true column check.
DROP POLICY IF EXISTS "Producers can update own unsold products" ON public.products;
CREATE POLICY "Producers can update own unsold products"
ON public.products
FOR UPDATE
TO authenticated
USING (
  producer_id = auth.uid()
  AND deleted_at IS NULL
  AND is_current_user_active(auth.uid())
  AND is_active_producer(auth.uid())
  AND NOT EXISTS (
    SELECT 1 FROM purchases pu
    WHERE pu.product_id = products.id
      AND pu.status = ANY (ARRAY['completed'::purchase_status, 'refunded'::purchase_status])
  )
)
WITH CHECK (
  producer_id = auth.uid()
  AND deleted_at IS NULL
  AND is_current_user_active(auth.uid())
  AND is_active_producer(auth.uid())
  AND NOT EXISTS (
    SELECT 1 FROM purchases pu
    WHERE pu.product_id = products.id
      AND pu.status = ANY (ARRAY['completed'::purchase_status, 'refunded'::purchase_status])
  )
  AND (
    NOT (COALESCE(is_elite, false) IS DISTINCT FROM private.current_product_is_elite(id))
    OR (
      EXISTS (
        SELECT 1 FROM user_profiles up
        WHERE up.id = auth.uid()
          AND up.account_type = 'elite_producer'
          AND is_active_producer(up.id)
          AND COALESCE(up.is_deleted, false) = false
          AND up.deleted_at IS NULL
      )
      AND private.current_product_is_elite(id) = true
    )
    OR (
      EXISTS (
        SELECT 1 FROM user_profiles up
        WHERE up.id = auth.uid()
          AND up.account_type = 'elite_producer'
          AND is_active_producer(up.id)
          AND COALESCE(up.is_deleted, false) = false
          AND up.deleted_at IS NULL
      )
      AND private.current_product_is_elite(id) = false
      AND COALESCE(is_elite, false) = true
      AND private.product_lineage_has_completed_sales(id) = false
      AND private.product_lineage_has_public_marketplace_history(id) = false
    )
  )
  AND (
    NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
    OR private.can_publish_beat(auth.uid(), id)
  )
);
