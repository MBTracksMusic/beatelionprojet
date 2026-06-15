-- Track and protect the country locked on a Stripe Connect account.
--
-- Stripe locks an account country after account creation when the platform sets
-- country/capabilities, so Beatelion must persist the country used for the
-- connected account and prevent users from spoofing Connect state locally.

BEGIN;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS stripe_account_country TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_stripe_account_country_check'
      AND conrelid = 'public.user_profiles'::regclass
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_stripe_account_country_check
      CHECK (stripe_account_country IS NULL OR stripe_account_country ~ '^[A-Z]{2}$');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_stripe_on_user_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.user_profiles
  SET
    stripe_account_id = NULL,
    stripe_account_charges_enabled = FALSE,
    stripe_account_details_submitted = FALSE,
    stripe_account_country = NULL,
    stripe_account_created_at = NULL
  WHERE id = OLD.id;

  RETURN OLD;
END;
$$;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_profiles'
      AND (
        qual ILIKE '%owner_can_update_profile%'
        OR with_check ILIKE '%owner_can_update_profile%'
      )
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON %I.%I',
      policy_record.policyname,
      policy_record.schemaname,
      policy_record.tablename
    );
  END LOOP;
END;
$$;

DROP POLICY IF EXISTS "Owner can update own profile" ON public.user_profiles;
DROP POLICY IF EXISTS "Advisor user profiles update" ON public.user_profiles;

DROP FUNCTION IF EXISTS private.owner_can_update_profile(
  uuid, public.user_role, public.producer_tier_type, boolean, boolean,
  text, text, public.subscription_status, integer, timestamptz, timestamptz,
  integer, integer, integer, integer, integer, integer, integer, integer,
  boolean, timestamptz, text, text, text, boolean
);

CREATE OR REPLACE FUNCTION private.owner_can_update_profile(
  p_user_id                         uuid,
  p_role                            public.user_role,
  p_producer_tier                   public.producer_tier_type,
  p_is_confirmed                    boolean,
  p_is_producer_active              boolean,
  p_stripe_customer_id              text,
  p_stripe_sub_id                   text,
  p_subscription_status             public.subscription_status,
  p_total_purchases                 integer,
  p_confirmed_at                    timestamptz,
  p_producer_verified_at            timestamptz,
  p_battle_refusal_count            integer,
  p_battles_participated            integer,
  p_battles_completed               integer,
  p_engagement_score                integer,
  p_elo_rating                      integer,
  p_battle_wins                     integer,
  p_battle_losses                   integer,
  p_battle_draws                    integer,
  p_is_deleted                      boolean,
  p_deleted_at                      timestamptz,
  p_delete_reason                   text,
  p_deleted_label                   text,
  p_account_type                    text,
  p_is_verified                     boolean,
  p_stripe_account_id               text,
  p_stripe_account_charges_enabled  boolean,
  p_stripe_account_details_submitted boolean,
  p_stripe_account_created_at       timestamptz,
  p_stripe_account_country          text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v record;
BEGIN
  SELECT
    role, producer_tier, is_confirmed, is_producer_active,
    stripe_customer_id, stripe_subscription_id, subscription_status,
    total_purchases, confirmed_at, producer_verified_at,
    battle_refusal_count, battles_participated, battles_completed,
    engagement_score, elo_rating, battle_wins, battle_losses, battle_draws,
    is_deleted, deleted_at, delete_reason, deleted_label,
    account_type, is_verified,
    stripe_account_id, stripe_account_charges_enabled,
    stripe_account_details_submitted, stripe_account_created_at,
    stripe_account_country
  INTO v
  FROM public.user_profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  RETURN (
    COALESCE(p_is_deleted, false) = false
    AND p_deleted_at IS NULL
    AND p_role                             IS NOT DISTINCT FROM v.role
    AND p_producer_tier                    IS NOT DISTINCT FROM v.producer_tier
    AND p_is_confirmed                     IS NOT DISTINCT FROM v.is_confirmed
    AND p_is_producer_active               IS NOT DISTINCT FROM v.is_producer_active
    AND p_stripe_customer_id               IS NOT DISTINCT FROM v.stripe_customer_id
    AND p_stripe_sub_id                    IS NOT DISTINCT FROM v.stripe_subscription_id
    AND p_subscription_status              IS NOT DISTINCT FROM v.subscription_status
    AND p_total_purchases                  IS NOT DISTINCT FROM v.total_purchases
    AND p_confirmed_at                     IS NOT DISTINCT FROM v.confirmed_at
    AND p_producer_verified_at             IS NOT DISTINCT FROM v.producer_verified_at
    AND p_battle_refusal_count             IS NOT DISTINCT FROM v.battle_refusal_count
    AND p_battles_participated             IS NOT DISTINCT FROM v.battles_participated
    AND p_battles_completed                IS NOT DISTINCT FROM v.battles_completed
    AND p_engagement_score                 IS NOT DISTINCT FROM v.engagement_score
    AND p_elo_rating                       IS NOT DISTINCT FROM v.elo_rating
    AND p_battle_wins                      IS NOT DISTINCT FROM v.battle_wins
    AND p_battle_losses                    IS NOT DISTINCT FROM v.battle_losses
    AND p_battle_draws                     IS NOT DISTINCT FROM v.battle_draws
    AND p_is_deleted                       IS NOT DISTINCT FROM v.is_deleted
    AND p_deleted_at                       IS NOT DISTINCT FROM v.deleted_at
    AND p_delete_reason                    IS NOT DISTINCT FROM v.delete_reason
    AND p_deleted_label                    IS NOT DISTINCT FROM v.deleted_label
    AND p_account_type                     IS NOT DISTINCT FROM v.account_type
    AND p_is_verified                      IS NOT DISTINCT FROM v.is_verified
    AND p_stripe_account_id                IS NOT DISTINCT FROM v.stripe_account_id
    AND p_stripe_account_charges_enabled   IS NOT DISTINCT FROM v.stripe_account_charges_enabled
    AND p_stripe_account_details_submitted IS NOT DISTINCT FROM v.stripe_account_details_submitted
    AND p_stripe_account_created_at        IS NOT DISTINCT FROM v.stripe_account_created_at
    AND p_stripe_account_country           IS NOT DISTINCT FROM v.stripe_account_country
  );
END;
$$;

REVOKE ALL ON FUNCTION private.owner_can_update_profile(
  uuid, public.user_role, public.producer_tier_type, boolean, boolean,
  text, text, public.subscription_status, integer, timestamptz, timestamptz,
  integer, integer, integer, integer, integer, integer, integer, integer,
  boolean, timestamptz, text, text, text, boolean,
  text, boolean, boolean, timestamptz, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.owner_can_update_profile(
  uuid, public.user_role, public.producer_tier_type, boolean, boolean,
  text, text, public.subscription_status, integer, timestamptz, timestamptz,
  integer, integer, integer, integer, integer, integer, integer, integer,
  boolean, timestamptz, text, text, text, boolean,
  text, boolean, boolean, timestamptz, text
) TO authenticated;

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
      account_type, is_verified,
      stripe_account_id, stripe_account_charges_enabled,
      stripe_account_details_submitted, stripe_account_created_at,
      stripe_account_country
    )
  );

COMMIT;
