-- Hotfix: lock down the RPCs created in 20260522190000 from anon/authenticated.
--
-- The previous migration only ran `REVOKE … FROM PUBLIC`, which does not
-- remove the default Supabase grants to `anon` and `authenticated`. The
-- security linter (advisor 0028/0029) therefore flagged all three new
-- functions as callable via /rest/v1/rpc/* by signed-out users.
--
-- Risk was low (each function has an internal admin or eligibility check),
-- but the surface should not exist in the first place.

BEGIN;

-- accept_waitlist_entry — admin-only RPC. Keep authenticated (the admin's
-- own user) but explicitly revoke from anon.
REVOKE EXECUTE ON FUNCTION public.accept_waitlist_entry(uuid) FROM anon;

-- promote_founding_producer_if_eligible — internal helper. Service role only.
REVOKE EXECUTE ON FUNCTION public.promote_founding_producer_if_eligible(uuid, text)
  FROM anon, authenticated;

-- auto_promote_founding_producer_on_profile_create — trigger function.
-- Never meant to be called directly via REST.
REVOKE EXECUTE ON FUNCTION public.auto_promote_founding_producer_on_profile_create()
  FROM anon, authenticated;

COMMIT;
