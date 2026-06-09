-- Drop only unused indexes that are left-prefix covered by another non-partial
-- or equivalent partial index. The remaining unused-index Advisor rows need
-- workload/statistics review before removal.

BEGIN;

DROP INDEX IF EXISTS public.idx_battle_vote_feedback_winner_product;
DROP INDEX IF EXISTS public.idx_battles_battle_type;
DROP INDEX IF EXISTS public.idx_battles_producer1;
DROP INDEX IF EXISTS public.idx_fraud_events_battle_id;
DROP INDEX IF EXISTS public.idx_fraud_events_user_id;
DROP INDEX IF EXISTS public.idx_play_events_user_product;
DROP INDEX IF EXISTS public.idx_product_licenses_product_id;
DROP INDEX IF EXISTS public.idx_purchases_product;
DROP INDEX IF EXISTS public.idx_purchases_status;
DROP INDEX IF EXISTS public.idx_purchases_user;
DROP INDEX IF EXISTS public.idx_user_profiles_deleted;
DROP INDEX IF EXISTS public.idx_user_profiles_is_producer;

COMMIT;
