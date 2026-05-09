-- supabase/migrations/20260510010000_fix_trial_campaign_active_filter.sql

-- Fix 1 (Critical): respect pc.is_active when checking trial validity.
-- A deactivated campaign should immediately revoke trial access.
--
-- The original LEFT JOIN + COALESCE approach was broken: when a campaign exists
-- but is deactivated (is_active = false), the LEFT JOIN still matched (returning
-- NULL for pc.trial_duration), and COALESCE fell back to 3 months — bypassing
-- the admin control lever entirely.
--
-- Correct logic:
--   - If producer_campaign_type IS NULL → no campaign assigned → use 3-month default.
--   - If producer_campaign_type IS SET  → campaign must exist AND be active;
--     if the campaign is deactivated the user gets no trial (no fallback).
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
    WHERE up.id = uid
      AND up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
      AND (
        -- Case 1: no campaign assigned → use 3-month default
        (
          up.producer_campaign_type IS NULL
          AND now() < up.founding_trial_start + interval '3 months'
        )
        OR
        -- Case 2: campaign assigned → it must be active; use its duration
        (
          up.producer_campaign_type IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM public.producer_campaigns pc
            WHERE pc.type = up.producer_campaign_type
              AND pc.is_active = true
              AND now() < up.founding_trial_start + pc.trial_duration
          )
        )
      )
  );
$$;

-- Fix 2 (Important): be explicit about SECURITY INVOKER on is_active_producer()
-- to match the codebase convention from the April 29 hardening pass.
CREATE OR REPLACE FUNCTION public.is_active_producer(p_user uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
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
