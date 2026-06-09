-- Drop redundant indexes that duplicate an existing UNIQUE index/constraint on
-- the same column. The UNIQUE index already serves every lookup the plain index
-- could, so the non-unique copy is pure write/maintenance overhead. These remain
-- flagged as "unused_index" by the Advisor but are safe to drop regardless of
-- pg_stat_user_indexes scan counts because the access path is fully preserved.
--
-- For each pair the plain idx_* is dropped, the UNIQUE index (…_key / uq_… /
-- unique_…) is kept:
--   idx_user_profiles_username              -> user_profiles_username_key
--   idx_user_profiles_stripe_customer       -> user_profiles_stripe_customer_id_key
--   idx_products_slug                       -> products_slug_key
--   idx_battles_slug                        -> battles_slug_key
--   idx_forum_post_attachments_post         -> forum_post_attachments_one_per_post
--   idx_producer_subscriptions_user         -> uq_producer_subscription_user
--   idx_producer_subscriptions_subscription -> uq_producer_subscription_stripe
--   idx_exclusive_locks_product             -> unique_product_lock
--
-- Plus one redundant non-unique pair on battles(producer1_id, created_at):
-- idx_battles_producer1_created_month (created_at DESC) and
-- idx_battles_producer1_monthly_quota (created_at ASC) are interchangeable
-- (btree scans both directions; producer1_id is an equality prefix). The newer
-- _monthly_quota index is kept (symmetric with idx_battles_producer2_monthly_quota);
-- the older _created_month index is dropped. Remove the last DROP below if you
-- would rather keep both.

BEGIN;

DROP INDEX IF EXISTS public.idx_user_profiles_username;
DROP INDEX IF EXISTS public.idx_user_profiles_stripe_customer;
DROP INDEX IF EXISTS public.idx_products_slug;
DROP INDEX IF EXISTS public.idx_battles_slug;
DROP INDEX IF EXISTS public.idx_forum_post_attachments_post;
DROP INDEX IF EXISTS public.idx_producer_subscriptions_user;
DROP INDEX IF EXISTS public.idx_producer_subscriptions_subscription;
DROP INDEX IF EXISTS public.idx_exclusive_locks_product;
DROP INDEX IF EXISTS public.idx_battles_producer1_created_month;

COMMIT;
