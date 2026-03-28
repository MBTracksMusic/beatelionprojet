BEGIN;

CREATE OR REPLACE FUNCTION public.cleanup_stripe_on_user_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Clear Stripe Connect data from user_profiles
  UPDATE public.user_profiles
  SET
    stripe_account_id = NULL,
    stripe_account_charges_enabled = FALSE,
    stripe_account_details_submitted = FALSE,
    stripe_account_created_at = NULL
  WHERE id = OLD.id;

  RETURN OLD;
END;
$$;

COMMIT;
