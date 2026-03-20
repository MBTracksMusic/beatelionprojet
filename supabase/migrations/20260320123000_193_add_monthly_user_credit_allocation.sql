/*
  # Monthly user credit allocation

  Adds:
  - invoice-level idempotency tracking for user credit allocation
  - atomic allocation function capped at 6 credits

  Business rules:
  - monthly allocation target: +3 credits
  - cumulative cap: 6 credits max
  - partial allocation allowed (for example 5 -> +1)
  - no ledger insert when allocation = 0
  - one processed invoice = one allocation event
*/

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Invoice-level idempotency / audit for allocations
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_credit_allocation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subscription_id uuid NOT NULL REFERENCES public.user_subscriptions(id) ON DELETE CASCADE,
  stripe_invoice_id text NOT NULL CHECK (btrim(stripe_invoice_id) <> ''),
  billing_period_start timestamptz NOT NULL,
  billing_period_end timestamptz NOT NULL,
  idempotency_key text NOT NULL CHECK (btrim(idempotency_key) <> ''),
  status text NOT NULL CHECK (
    status IN ('processed', 'skipped_max_balance', 'skipped_inactive_subscription')
  ),
  allocated_credits integer NOT NULL CHECK (allocated_credits >= 0),
  previous_balance integer NOT NULL CHECK (previous_balance >= 0),
  new_balance integer NOT NULL CHECK (new_balance >= 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_credit_allocation_events_invoice UNIQUE (stripe_invoice_id),
  CONSTRAINT uq_user_credit_allocation_events_idempotency UNIQUE (idempotency_key),
  CONSTRAINT ck_user_credit_allocation_events_period CHECK (
    billing_period_end > billing_period_start
  )
);

CREATE INDEX IF NOT EXISTS idx_user_credit_allocation_events_user_created_desc
  ON public.user_credit_allocation_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_credit_allocation_events_subscription_created_desc
  ON public.user_credit_allocation_events (subscription_id, created_at DESC);

ALTER TABLE public.user_credit_allocation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "User credit allocation events: owner can read" ON public.user_credit_allocation_events;
CREATE POLICY "User credit allocation events: owner can read"
  ON public.user_credit_allocation_events
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Intentionally no authenticated write policy. Webhook/service role only.

COMMENT ON TABLE public.user_credit_allocation_events IS
  'Invoice-level idempotency and audit trail for monthly user credit allocations. Prevents duplicate credits across Stripe retries.';

-- ---------------------------------------------------------------------------
-- 2) Atomic allocation RPC for webhook/service role
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.allocate_monthly_user_credits_for_invoice(
  p_stripe_invoice_id text,
  p_stripe_subscription_id text,
  p_billing_period_start timestamptz,
  p_billing_period_end timestamptz,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_subscription public.user_subscriptions%ROWTYPE;
  v_current_balance integer := 0;
  v_allocation integer := 0;
  v_new_balance integer := 0;
  v_idempotency_key text;
  v_existing_event public.user_credit_allocation_events%ROWTYPE;
BEGIN
  IF p_stripe_invoice_id IS NULL OR btrim(p_stripe_invoice_id) = '' THEN
    RAISE EXCEPTION 'missing_stripe_invoice_id' USING ERRCODE = '22023';
  END IF;

  IF p_stripe_subscription_id IS NULL OR btrim(p_stripe_subscription_id) = '' THEN
    RAISE EXCEPTION 'missing_stripe_subscription_id' USING ERRCODE = '22023';
  END IF;

  IF p_billing_period_start IS NULL OR p_billing_period_end IS NULL OR p_billing_period_end <= p_billing_period_start THEN
    RAISE EXCEPTION 'invalid_billing_period' USING ERRCODE = '22023';
  END IF;

  v_idempotency_key := format('credit_allocation:%s', btrim(p_stripe_invoice_id));

  -- Serialize retries for the same invoice inside the transaction.
  PERFORM pg_advisory_xact_lock(hashtext(v_idempotency_key));

  SELECT *
  INTO v_existing_event
  FROM public.user_credit_allocation_events
  WHERE idempotency_key = v_idempotency_key
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'user_id', v_existing_event.user_id,
      'subscription_id', v_existing_event.subscription_id,
      'allocated_credits', v_existing_event.allocated_credits,
      'previous_balance', v_existing_event.previous_balance,
      'new_balance', v_existing_event.new_balance,
      'stripe_invoice_id', p_stripe_invoice_id,
      'billing_period_start', v_existing_event.billing_period_start,
      'billing_period_end', v_existing_event.billing_period_end
    );
  END IF;

  SELECT *
  INTO v_subscription
  FROM public.user_subscriptions
  WHERE stripe_subscription_id = p_stripe_subscription_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_subscription_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Serialize all future credit mutations per user.
  PERFORM pg_advisory_xact_lock(hashtext(v_subscription.user_id::text));

  SELECT COALESCE(SUM(balance_delta), 0)::integer
  INTO v_current_balance
  FROM public.user_credit_ledger
  WHERE user_id = v_subscription.user_id;

  IF v_subscription.subscription_status NOT IN ('active', 'trialing') THEN
    INSERT INTO public.user_credit_allocation_events (
      user_id,
      subscription_id,
      stripe_invoice_id,
      billing_period_start,
      billing_period_end,
      idempotency_key,
      status,
      allocated_credits,
      previous_balance,
      new_balance,
      metadata
    ) VALUES (
      v_subscription.user_id,
      v_subscription.id,
      p_stripe_invoice_id,
      p_billing_period_start,
      p_billing_period_end,
      v_idempotency_key,
      'skipped_inactive_subscription',
      0,
      v_current_balance,
      v_current_balance,
      COALESCE(p_metadata, '{}'::jsonb)
    );

    RETURN jsonb_build_object(
      'status', 'skipped_inactive_subscription',
      'user_id', v_subscription.user_id,
      'subscription_id', v_subscription.id,
      'allocated_credits', 0,
      'previous_balance', v_current_balance,
      'new_balance', v_current_balance,
      'stripe_invoice_id', p_stripe_invoice_id,
      'billing_period_start', p_billing_period_start,
      'billing_period_end', p_billing_period_end
    );
  END IF;

  IF v_current_balance >= 6 THEN
    INSERT INTO public.user_credit_allocation_events (
      user_id,
      subscription_id,
      stripe_invoice_id,
      billing_period_start,
      billing_period_end,
      idempotency_key,
      status,
      allocated_credits,
      previous_balance,
      new_balance,
      metadata
    ) VALUES (
      v_subscription.user_id,
      v_subscription.id,
      p_stripe_invoice_id,
      p_billing_period_start,
      p_billing_period_end,
      v_idempotency_key,
      'skipped_max_balance',
      0,
      v_current_balance,
      v_current_balance,
      COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
        'allocation_target', 3,
        'balance_cap', 6
      )
    );

    RETURN jsonb_build_object(
      'status', 'skipped_max_balance',
      'user_id', v_subscription.user_id,
      'subscription_id', v_subscription.id,
      'allocated_credits', 0,
      'previous_balance', v_current_balance,
      'new_balance', v_current_balance,
      'stripe_invoice_id', p_stripe_invoice_id,
      'billing_period_start', p_billing_period_start,
      'billing_period_end', p_billing_period_end
    );
  END IF;

  v_allocation := LEAST(3, GREATEST(0, 6 - v_current_balance));
  v_new_balance := v_current_balance + v_allocation;

  INSERT INTO public.user_credit_ledger (
    user_id,
    subscription_id,
    entry_type,
    direction,
    credits_amount,
    balance_delta,
    running_balance,
    reason,
    stripe_invoice_id,
    billing_period_start,
    billing_period_end,
    idempotency_key,
    metadata
  ) VALUES (
    v_subscription.user_id,
    v_subscription.id,
    'monthly_allocation',
    'credit',
    v_allocation,
    v_allocation,
    v_new_balance,
    'monthly_allocation',
    p_stripe_invoice_id,
    p_billing_period_start,
    p_billing_period_end,
    v_idempotency_key,
    COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'allocation_target', 3,
      'balance_cap', 6
    )
  );

  INSERT INTO public.user_credit_allocation_events (
    user_id,
    subscription_id,
    stripe_invoice_id,
    billing_period_start,
    billing_period_end,
    idempotency_key,
    status,
    allocated_credits,
    previous_balance,
    new_balance,
    metadata
  ) VALUES (
    v_subscription.user_id,
    v_subscription.id,
    p_stripe_invoice_id,
    p_billing_period_start,
    p_billing_period_end,
    v_idempotency_key,
    'processed',
    v_allocation,
    v_current_balance,
    v_new_balance,
    COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'allocation_target', 3,
      'balance_cap', 6
    )
  );

  RETURN jsonb_build_object(
    'status', 'processed',
    'user_id', v_subscription.user_id,
    'subscription_id', v_subscription.id,
    'allocated_credits', v_allocation,
    'previous_balance', v_current_balance,
    'new_balance', v_new_balance,
    'stripe_invoice_id', p_stripe_invoice_id,
    'billing_period_start', p_billing_period_start,
    'billing_period_end', p_billing_period_end
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.allocate_monthly_user_credits_for_invoice(text, text, timestamptz, timestamptz, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.allocate_monthly_user_credits_for_invoice(text, text, timestamptz, timestamptz, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.allocate_monthly_user_credits_for_invoice(text, text, timestamptz, timestamptz, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_monthly_user_credits_for_invoice(text, text, timestamptz, timestamptz, jsonb) TO service_role;

COMMENT ON FUNCTION public.allocate_monthly_user_credits_for_invoice(text, text, timestamptz, timestamptz, jsonb) IS
  'Atomic and idempotent monthly allocation for buyer credits. Uses credit_allocation:{invoice_id}. No ledger insert is created when allocation is skipped because the user already has 6 credits.';

COMMIT;
