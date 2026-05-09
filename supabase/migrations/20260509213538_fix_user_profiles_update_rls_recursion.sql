-- Fix: infinite recursion in "Owner can update own profile" RLS policy
--
-- Root cause: the WITH CHECK clause used sub-selects on user_profiles to compare
-- each protected column against its current DB value. When running as the
-- `authenticated` role those sub-selects re-enter the SELECT RLS policies on
-- user_profiles, causing PostgreSQL to detect infinite recursion and return 500.
--
-- Fix: replace every sub-select with a single SECURITY DEFINER helper that reads
-- the protected columns directly (bypassing RLS), then passes the values back to
-- the policy expression for comparison against the NEW row.

-- 1. SECURITY DEFINER helper: reads the protected fields for one user without RLS.
CREATE OR REPLACE FUNCTION private.owner_can_update_profile(
  p_user_id             uuid,
  -- NEW row values for every protected column (passed from the policy expression)
  p_role                public.user_role,
  p_producer_tier       public.producer_tier_type,
  p_is_confirmed        boolean,
  p_is_producer_active  boolean,
  p_stripe_customer_id  text,
  p_stripe_sub_id       text,
  p_subscription_status public.subscription_status,
  p_total_purchases     integer,
  p_confirmed_at        timestamptz,
  p_producer_verified_at timestamptz,
  p_battle_refusal_count integer,
  p_battles_participated integer,
  p_battles_completed   integer,
  p_engagement_score    integer,
  p_elo_rating          integer,
  p_battle_wins         integer,
  p_battle_losses       integer,
  p_battle_draws        integer,
  p_is_deleted          boolean,
  p_deleted_at          timestamptz,
  p_delete_reason       text,
  p_deleted_label       text,
  p_account_type        text,
  p_is_verified         boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v record;
BEGIN
  -- Read current (OLD) values bypassing RLS thanks to SECURITY DEFINER +
  -- the function owner having rolbypassrls = true.
  SELECT
    role, producer_tier, is_confirmed, is_producer_active,
    stripe_customer_id, stripe_subscription_id, subscription_status,
    total_purchases, confirmed_at, producer_verified_at,
    battle_refusal_count, battles_participated, battles_completed,
    engagement_score, elo_rating, battle_wins, battle_losses, battle_draws,
    is_deleted, deleted_at, delete_reason, deleted_label,
    account_type, is_verified
  INTO v
  FROM public.user_profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  RETURN (
    -- Soft-delete guard: owner can never set these to a deleted state
    COALESCE(p_is_deleted, false) = false
    AND p_deleted_at IS NULL
    -- Protected columns must not change
    AND p_role                   IS NOT DISTINCT FROM v.role
    AND p_producer_tier          IS NOT DISTINCT FROM v.producer_tier
    AND p_is_confirmed           IS NOT DISTINCT FROM v.is_confirmed
    AND p_is_producer_active     IS NOT DISTINCT FROM v.is_producer_active
    AND p_stripe_customer_id     IS NOT DISTINCT FROM v.stripe_customer_id
    AND p_stripe_sub_id          IS NOT DISTINCT FROM v.stripe_subscription_id
    AND p_subscription_status    IS NOT DISTINCT FROM v.subscription_status
    AND p_total_purchases        IS NOT DISTINCT FROM v.total_purchases
    AND p_confirmed_at           IS NOT DISTINCT FROM v.confirmed_at
    AND p_producer_verified_at   IS NOT DISTINCT FROM v.producer_verified_at
    AND p_battle_refusal_count   IS NOT DISTINCT FROM v.battle_refusal_count
    AND p_battles_participated   IS NOT DISTINCT FROM v.battles_participated
    AND p_battles_completed      IS NOT DISTINCT FROM v.battles_completed
    AND p_engagement_score       IS NOT DISTINCT FROM v.engagement_score
    AND p_elo_rating             IS NOT DISTINCT FROM v.elo_rating
    AND p_battle_wins            IS NOT DISTINCT FROM v.battle_wins
    AND p_battle_losses          IS NOT DISTINCT FROM v.battle_losses
    AND p_battle_draws           IS NOT DISTINCT FROM v.battle_draws
    AND p_is_deleted             IS NOT DISTINCT FROM v.is_deleted
    AND p_deleted_at             IS NOT DISTINCT FROM v.deleted_at
    AND p_delete_reason          IS NOT DISTINCT FROM v.delete_reason
    AND p_deleted_label          IS NOT DISTINCT FROM v.deleted_label
    AND p_account_type           IS NOT DISTINCT FROM v.account_type
    AND p_is_verified            IS NOT DISTINCT FROM v.is_verified
  );
END;
$$;

REVOKE ALL ON FUNCTION private.owner_can_update_profile(
  uuid, public.user_role, public.producer_tier_type, boolean, boolean,
  text, text, public.subscription_status, integer, timestamptz, timestamptz,
  integer, integer, integer, integer, integer, integer, integer, integer,
  boolean, timestamptz, text, text, text, boolean
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION private.owner_can_update_profile(
  uuid, public.user_role, public.producer_tier_type, boolean, boolean,
  text, text, public.subscription_status, integer, timestamptz, timestamptz,
  integer, integer, integer, integer, integer, integer, integer, integer,
  boolean, timestamptz, text, text, text, boolean
) TO authenticated;

-- 2. Recreate the policy, replacing every sub-select with the helper call.
--    In a WITH CHECK expression, bare column names refer to the NEW row.
DROP POLICY IF EXISTS "Owner can update own profile" ON public.user_profiles;

CREATE POLICY "Owner can update own profile"
  ON public.user_profiles
  FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (
    id = auth.uid()
    AND private.owner_can_update_profile(
      auth.uid(),
      role, producer_tier, is_confirmed, is_producer_active,
      stripe_customer_id, stripe_subscription_id, subscription_status,
      total_purchases, confirmed_at, producer_verified_at,
      battle_refusal_count, battles_participated, battles_completed,
      engagement_score, elo_rating, battle_wins, battle_losses, battle_draws,
      is_deleted, deleted_at, delete_reason, deleted_label,
      account_type, is_verified
    )
  );
