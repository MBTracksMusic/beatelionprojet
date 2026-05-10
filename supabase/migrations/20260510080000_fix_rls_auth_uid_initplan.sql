-- Fix auth_rls_initplan warnings: replace bare auth.uid() with (SELECT auth.uid())
-- Pure performance optimisation — zero security logic change.
-- Skipped: Stripe/payment tables, battle tables, waitlist, marketplace producer policies.

-- ---------------------------------------------------------------------------
-- cart_items
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Users can add to cart" ON public.cart_items;
CREATE POLICY "Users can add to cart"
  ON public.cart_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (user_id = (SELECT auth.uid()))
    AND private.user_can_add_product_to_cart((SELECT auth.uid()), product_id)
  );

-- ---------------------------------------------------------------------------
-- forum_categories
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum categories readable" ON public.forum_categories;
CREATE POLICY "Forum categories readable"
  ON public.forum_categories
  FOR SELECT
  TO anon, authenticated
  USING (
    (is_premium_only = false)
    OR private.forum_has_active_subscription((SELECT auth.uid()))
    OR ((slug = 'annonces-label'::text) AND private.forum_is_verified_label((SELECT auth.uid())))
  );

-- ---------------------------------------------------------------------------
-- forum_post_attachments
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Forum post attachments readable" ON public.forum_post_attachments;
CREATE POLICY "Forum post attachments readable"
  ON public.forum_post_attachments
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM ((forum_posts fp
        JOIN forum_topics ft ON (ft.id = fp.topic_id))
        JOIN forum_categories fc ON (fc.id = ft.category_id))
      WHERE (
        fp.id = forum_post_attachments.post_id
        AND COALESCE(fc.allow_media, true) = true
        AND forum_can_access_category(ft.category_id, (SELECT auth.uid()))
        AND (
          private.is_admin((SELECT auth.uid()))
          OR fp.user_id = (SELECT auth.uid())
          OR (COALESCE(fp.is_deleted, false) = false AND COALESCE(fp.is_visible, true) = true)
        )
      )
    )
  );

-- ---------------------------------------------------------------------------
-- label_requests
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Admins can read label requests" ON public.label_requests;
CREATE POLICY "Admins can read label requests"
  ON public.label_requests
  FOR SELECT
  TO authenticated
  USING (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Admins can update label requests" ON public.label_requests;
CREATE POLICY "Admins can update label requests"
  ON public.label_requests
  FOR UPDATE
  TO authenticated
  USING (private.is_admin((SELECT auth.uid())))
  WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Users can create own label requests" ON public.label_requests;
CREATE POLICY "Users can create own label requests"
  ON public.label_requests
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (user_id = (SELECT auth.uid()))
    AND (status = 'pending'::text)
    AND (reviewed_at IS NULL)
    AND (reviewed_by IS NULL)
  );

DROP POLICY IF EXISTS "Users can read own label requests" ON public.label_requests;
CREATE POLICY "Users can read own label requests"
  ON public.label_requests
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- products — admin policy only; producer/marketplace policies untouched
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Admins can update products" ON public.products;
CREATE POLICY "Admins can update products"
  ON public.products
  FOR UPDATE
  TO authenticated
  USING (private.is_admin((SELECT auth.uid())))
  WITH CHECK (private.is_admin((SELECT auth.uid())));

-- ---------------------------------------------------------------------------
-- user_profiles
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Admins can update all user profiles" ON public.user_profiles;
CREATE POLICY "Admins can update all user profiles"
  ON public.user_profiles
  FOR UPDATE
  TO authenticated
  USING (private.is_admin((SELECT auth.uid())))
  WITH CHECK (private.is_admin((SELECT auth.uid())));

DROP POLICY IF EXISTS "Owner can update own profile" ON public.user_profiles;
CREATE POLICY "Owner can update own profile"
  ON public.user_profiles
  FOR UPDATE
  TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (
    (id = (SELECT auth.uid()))
    AND private.owner_can_update_profile(
      (SELECT auth.uid()),
      role, producer_tier, is_confirmed, is_producer_active,
      stripe_customer_id, stripe_subscription_id, subscription_status,
      total_purchases, confirmed_at, producer_verified_at,
      battle_refusal_count, battles_participated, battles_completed,
      engagement_score, elo_rating, battle_wins, battle_losses, battle_draws,
      is_deleted, deleted_at, delete_reason, deleted_label,
      account_type, is_verified
    )
  );
