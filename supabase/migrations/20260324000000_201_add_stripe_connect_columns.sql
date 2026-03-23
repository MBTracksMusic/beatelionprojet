/*
  Add Stripe Connect columns to user_profiles

  Enables producers to:
  - Onboard to Stripe Connect
  - Receive direct payments to their Stripe account
  - Get notifications when charges are enabled

  Columns:
  - stripe_account_id: Stripe Connect account ID (acct_...)
  - stripe_account_charges_enabled: Whether this account can receive charges
  - stripe_account_details_submitted: Whether account details were submitted
  - stripe_account_created_at: When the Stripe Connect account was created
*/

BEGIN;

-- Add Stripe Connect columns to user_profiles
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS stripe_account_id VARCHAR(255),
  ADD COLUMN IF NOT EXISTS stripe_account_charges_enabled BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS stripe_account_details_submitted BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS stripe_account_created_at TIMESTAMP WITH TIME ZONE;

-- Create index on stripe_account_id for faster lookups
CREATE INDEX IF NOT EXISTS idx_user_profiles_stripe_account_id
  ON public.user_profiles(stripe_account_id);

COMMIT;
