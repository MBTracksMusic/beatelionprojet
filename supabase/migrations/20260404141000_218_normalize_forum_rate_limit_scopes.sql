/*
  # Normalize forum rate-limit scopes

  Goal:
  - make user-facing forum rate-limit rules explicit
  - keep the existing per-user behavior while removing the misleading per_admin label
*/

BEGIN;

UPDATE public.rpc_rate_limit_rules
SET
  scope = 'per_user',
  updated_at = now()
WHERE rpc_name IN (
  'forum_create_topic',
  'forum_create_post',
  'forum_assistant_dispatch'
);

COMMIT;
