/*
  # Reduce SECURITY DEFINER lint noise for invoker-safe public RPCs

  The previous hardening migration made RPC execute grants explicit. This pass
  converts only the public read RPCs whose underlying sources are already
  exposed through public-safe tables/views with SELECT grants for anon and
  authenticated roles.

  Do not convert profile, admin, quota, purchase, battle vote, or visibility
  projection RPCs here. Those functions intentionally run as SECURITY DEFINER
  to enforce the existing business visibility rules without granting direct
  table access.
*/

BEGIN;

ALTER FUNCTION public.get_active_season() SECURITY INVOKER;
ALTER FUNCTION public.get_active_season_details() SECURITY INVOKER;
ALTER FUNCTION public.get_weekly_leaderboard(integer) SECURITY INVOKER;
ALTER FUNCTION public.get_beats_with_priority() SECURITY INVOKER;
ALTER FUNCTION public.get_producer_top_beats(uuid) SECURITY INVOKER;

GRANT EXECUTE ON FUNCTION public.get_active_season() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_active_season_details() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboard(integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_beats_with_priority() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_producer_top_beats(uuid) TO anon, authenticated, service_role;

COMMIT;
