/*
  # Phase 0 user subscriptions + credit ledger + purchase economics snapshots

  Goals:
  - Add a dedicated user subscription table, fully separate from producer_subscriptions
  - Add a transactional credit ledger as the source of truth
  - Enrich purchases with future payout-friendly economic snapshots
  - Add owner-read RPCs for user subscription / credit balance / credit history

  Notes:
  - This migration does NOT implement credit allocation or credit purchases yet.
  - This migration does NOT implement producer payout periods.
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Dedicated user subscriptions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_code text NOT NULL CHECK (btrim(plan_code) <> ''),
  stripe_customer_id text NOT NULL CHECK (btrim(stripe_customer_id) <> ''),
  stripe_subscription_id text NOT NULL CHECK (btrim(stripe_subscription_id) <> ''),
  stripe_price_id text NOT NULL CHECK (btrim(stripe_price_id) <> ''),
  subscription_status public.subscription_status NOT NULL,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  canceled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_subscriptions_user UNIQUE (user_id),
  CONSTRAINT uq_user_subscriptions_stripe_subscription UNIQUE (stripe_subscription_id),
  CONSTRAINT ck_user_subscriptions_canceled_requires_state CHECK (
    canceled_at IS NULL OR subscription_status IN ('canceled', 'unpaid', 'incomplete_expired', 'paused')
  ),
  CONSTRAINT ck_user_subscriptions_period_order CHECK (
    current_period_start IS NULL
    OR current_period_end IS NULL
    OR current_period_end >= current_period_start
  )
);

CREATE INDEX IF NOT EXISTS idx_user_subscriptions_customer
  ON public.user_subscriptions (stripe_customer_id);

CREATE INDEX IF NOT EXISTS idx_user_subscriptions_status_period_end
  ON public.user_subscriptions (subscription_status, current_period_end DESC);

CREATE OR REPLACE FUNCTION public.set_user_subscription_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_subscriptions_updated_at ON public.user_subscriptions;
CREATE TRIGGER trg_user_subscriptions_updated_at
  BEFORE UPDATE ON public.user_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_user_subscription_updated_at();

ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "User subscriptions: owner can read" ON public.user_subscriptions;
CREATE POLICY "User subscriptions: owner can read"
  ON public.user_subscriptions
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Intentionally no authenticated write policy. Webhook/service role only.

COMMENT ON TABLE public.user_subscriptions IS
  'Dedicated buyer/user subscriptions. Separate source of truth from producer_subscriptions.';

-- ---------------------------------------------------------------------------
-- 2) Credit ledger as the source of truth
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_credit_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subscription_id uuid REFERENCES public.user_subscriptions(id) ON DELETE SET NULL,
  purchase_id uuid REFERENCES public.purchases(id) ON DELETE SET NULL,
  entry_type text NOT NULL CHECK (
    entry_type IN (
      'monthly_allocation',
      'purchase_debit',
      'reversal',
      'admin_adjustment',
      'migration_adjustment'
    )
  ),
  direction text NOT NULL CHECK (direction IN ('credit', 'debit')),
  credits_amount integer NOT NULL CHECK (credits_amount > 0),
  balance_delta integer NOT NULL,
  running_balance integer,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  stripe_invoice_id text,
  billing_period_start timestamptz,
  billing_period_end timestamptz,
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> ''),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_credit_ledger_idempotency_key UNIQUE (idempotency_key),
  CONSTRAINT ck_user_credit_ledger_balance_direction CHECK (
    (direction = 'credit' AND balance_delta > 0)
    OR (direction = 'debit' AND balance_delta < 0)
  ),
  CONSTRAINT ck_user_credit_ledger_balance_abs_matches_amount CHECK (
    abs(balance_delta) = credits_amount
  ),
  CONSTRAINT ck_user_credit_ledger_running_balance_non_negative CHECK (
    running_balance IS NULL OR running_balance >= 0
  ),
  CONSTRAINT ck_user_credit_ledger_purchase_debit_requires_purchase CHECK (
    entry_type <> 'purchase_debit' OR purchase_id IS NOT NULL
  ),
  CONSTRAINT ck_user_credit_ledger_monthly_allocation_period CHECK (
    entry_type <> 'monthly_allocation'
    OR (
      stripe_invoice_id IS NOT NULL
      AND billing_period_start IS NOT NULL
      AND billing_period_end IS NOT NULL
      AND billing_period_end > billing_period_start
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_user_credit_ledger_user_created_desc
  ON public.user_credit_ledger (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_credit_ledger_subscription_created_desc
  ON public.user_credit_ledger (subscription_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_credit_ledger_purchase
  ON public.user_credit_ledger (purchase_id)
  WHERE purchase_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_credit_ledger_invoice
  ON public.user_credit_ledger (stripe_invoice_id)
  WHERE stripe_invoice_id IS NOT NULL;

ALTER TABLE public.user_credit_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "User credit ledger: owner can read" ON public.user_credit_ledger;
CREATE POLICY "User credit ledger: owner can read"
  ON public.user_credit_ledger
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Intentionally no authenticated write policy. Webhook/service role only.

COMMENT ON TABLE public.user_credit_ledger IS
  'Immutable credit ledger. Source of truth for buyer credits. running_balance is an optional projection, not the source of truth.';

-- ---------------------------------------------------------------------------
-- 3) Purchase economics snapshots for future credit purchases / pool payouts
-- ---------------------------------------------------------------------------
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS purchase_source text,
  ADD COLUMN IF NOT EXISTS credits_spent integer,
  ADD COLUMN IF NOT EXISTS credit_unit_value_cents_snapshot integer,
  ADD COLUMN IF NOT EXISTS gross_reference_amount_cents integer,
  ADD COLUMN IF NOT EXISTS producer_share_cents_snapshot integer,
  ADD COLUMN IF NOT EXISTS platform_share_cents_snapshot integer;

UPDATE public.purchases
SET
  purchase_source = COALESCE(purchase_source, 'stripe_checkout'),
  gross_reference_amount_cents = COALESCE(gross_reference_amount_cents, amount)
WHERE purchase_source IS NULL
   OR gross_reference_amount_cents IS NULL;

ALTER TABLE public.purchases
  ALTER COLUMN purchase_source SET DEFAULT 'stripe_checkout';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ck_purchases_purchase_source'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT ck_purchases_purchase_source
      CHECK (purchase_source IN ('stripe_checkout', 'credits'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ck_purchases_credits_spent_positive'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT ck_purchases_credits_spent_positive
      CHECK (credits_spent IS NULL OR credits_spent > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ck_purchases_credit_snapshots_positive'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT ck_purchases_credit_snapshots_positive
      CHECK (
        (credit_unit_value_cents_snapshot IS NULL OR credit_unit_value_cents_snapshot >= 0)
        AND (gross_reference_amount_cents IS NULL OR gross_reference_amount_cents >= 0)
        AND (producer_share_cents_snapshot IS NULL OR producer_share_cents_snapshot >= 0)
        AND (platform_share_cents_snapshot IS NULL OR platform_share_cents_snapshot >= 0)
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ck_purchases_credit_fields_match_source'
      AND conrelid = 'public.purchases'::regclass
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT ck_purchases_credit_fields_match_source
      CHECK (
        (purchase_source = 'stripe_checkout' AND credits_spent IS NULL)
        OR (purchase_source = 'credits' AND credits_spent IS NOT NULL)
      );
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_purchases_purchase_source
  ON public.purchases (purchase_source, created_at DESC);

COMMENT ON COLUMN public.purchases.purchase_source IS
  'stripe_checkout for direct money purchases, credits for future wallet/credit purchases.';
COMMENT ON COLUMN public.purchases.credits_spent IS
  'Number of credits consumed for a credit purchase. NULL for stripe_checkout purchases.';
COMMENT ON COLUMN public.purchases.credit_unit_value_cents_snapshot IS
  'Economic reference value of one credit at purchase time. Future payout/accounting use.';
COMMENT ON COLUMN public.purchases.gross_reference_amount_cents IS
  'Reference gross amount used for financial analytics/payout formulas. Defaults to amount for Stripe purchases.';
COMMENT ON COLUMN public.purchases.producer_share_cents_snapshot IS
  'Producer share snapshot at purchase time when the business rule is known.';
COMMENT ON COLUMN public.purchases.platform_share_cents_snapshot IS
  'Platform share snapshot at purchase time when the business rule is known.';

-- ---------------------------------------------------------------------------
-- 4) Owner-read RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_user_subscription_status()
RETURNS TABLE (
  id uuid,
  plan_code text,
  stripe_price_id text,
  subscription_status public.subscription_status,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  canceled_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    us.id,
    us.plan_code,
    us.stripe_price_id,
    us.subscription_status,
    us.current_period_start,
    us.current_period_end,
    us.cancel_at_period_end,
    us.canceled_at,
    us.created_at,
    us.updated_at
  FROM public.user_subscriptions us
  WHERE us.user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_my_credit_balance()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(ucl.balance_delta), 0)::integer
  FROM public.user_credit_ledger ucl
  WHERE ucl.user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_my_credit_history()
RETURNS TABLE (
  id uuid,
  subscription_id uuid,
  purchase_id uuid,
  entry_type text,
  direction text,
  credits_amount integer,
  balance_delta integer,
  running_balance integer,
  reason text,
  stripe_invoice_id text,
  billing_period_start timestamptz,
  billing_period_end timestamptz,
  metadata jsonb,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    ucl.id,
    ucl.subscription_id,
    ucl.purchase_id,
    ucl.entry_type,
    ucl.direction,
    ucl.credits_amount,
    ucl.balance_delta,
    ucl.running_balance,
    ucl.reason,
    ucl.stripe_invoice_id,
    ucl.billing_period_start,
    ucl.billing_period_end,
    ucl.metadata,
    ucl.created_at
  FROM public.user_credit_ledger ucl
  WHERE ucl.user_id = auth.uid()
  ORDER BY ucl.created_at DESC, ucl.id DESC;
$$;

REVOKE EXECUTE ON FUNCTION public.get_my_user_subscription_status() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_user_subscription_status() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_user_subscription_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_user_subscription_status() TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_my_credit_balance() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_credit_balance() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_credit_balance() TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_my_credit_history() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_credit_history() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_history() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_credit_history() TO service_role;

COMMIT;
