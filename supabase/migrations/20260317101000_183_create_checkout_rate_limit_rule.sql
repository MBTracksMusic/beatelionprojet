/*
  # Add dedicated rate limit for create-checkout

  Rule:
  - create_checkout_user: 8 requests / minute / user
*/

BEGIN;

INSERT INTO public.rpc_rate_limit_rules (
  rpc_name,
  scope,
  allowed_per_minute,
  is_enabled
)
VALUES (
  'create_checkout_user',
  'per_user',
  8,
  true
)
ON CONFLICT (rpc_name)
DO UPDATE SET
  scope = EXCLUDED.scope,
  allowed_per_minute = EXCLUDED.allowed_per_minute,
  is_enabled = EXCLUDED.is_enabled,
  updated_at = now();

COMMIT;
