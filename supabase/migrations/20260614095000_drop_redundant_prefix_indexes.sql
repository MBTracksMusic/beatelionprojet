/*
  # Drop redundant prefix indexes

  Keep the existing primary/unique constraints that start with the same leading
  columns. These standalone indexes are unused and covered by those constraints,
  so removing them reduces write/maintenance overhead without changing data
  rules, RLS, functions, or business logic.
*/

BEGIN;

DROP INDEX IF EXISTS public.idx_battle_quality_snapshots_battle;
DROP INDEX IF EXISTS public.idx_battle_votes_battle;
DROP INDEX IF EXISTS public.idx_cart_items_user;
DROP INDEX IF EXISTS public.idx_entitlements_user_id;
DROP INDEX IF EXISTS public.idx_user_badges_user_id;
DROP INDEX IF EXISTS public.idx_user_music_preferences_user;
DROP INDEX IF EXISTS public.idx_wishlists_user;

COMMIT;
