/*
  # Event bus pipeline (auth/users/business events -> event_bus -> handlers -> email_queue)

  Objectifs:
  - centraliser les evenements metier dans `public.event_bus`
  - traiter les evenements via un worker Edge Function (`process-events`)
  - alimenter `public.email_queue` sans casser les flux existants
*/

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Event bus + handlers
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.event_bus (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text NOT NULL,
  aggregate_type text,
  aggregate_id uuid,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 5,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  locked_at timestamptz,
  last_error text
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_bus_status_check'
      AND conrelid = 'public.event_bus'::regclass
  ) THEN
    ALTER TABLE public.event_bus
      ADD CONSTRAINT event_bus_status_check
      CHECK (status IN ('pending', 'processing', 'processed', 'failed'));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_bus_event_type_check'
      AND conrelid = 'public.event_bus'::regclass
  ) THEN
    ALTER TABLE public.event_bus
      ADD CONSTRAINT event_bus_event_type_check
      CHECK (
        event_type IN (
          'USER_SIGNUP',
          'USER_CONFIRMED',
          'PRODUCER_ACTIVATED',
          'BEAT_PURCHASED',
          'LICENSE_GENERATED',
          'BATTLE_WON',
          'COMMENT_RECEIVED'
        )
      );
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS event_bus_status_idx
  ON public.event_bus (status);

CREATE INDEX IF NOT EXISTS event_bus_event_type_idx
  ON public.event_bus (event_type);

CREATE INDEX IF NOT EXISTS event_bus_created_idx
  ON public.event_bus (created_at);

CREATE INDEX IF NOT EXISTS event_bus_status_created_idx
  ON public.event_bus (status, created_at);

-- Idempotence: un event identique sur le meme aggregate ne doit etre produit qu'une seule fois.
CREATE UNIQUE INDEX IF NOT EXISTS event_bus_event_aggregate_unique_idx
  ON public.event_bus (event_type, aggregate_id)
  WHERE aggregate_id IS NOT NULL;

ALTER TABLE public.event_bus ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.event_bus FROM anon;
REVOKE ALL ON TABLE public.event_bus FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.event_bus TO service_role;

DROP POLICY IF EXISTS "Service role can manage event bus" ON public.event_bus;
CREATE POLICY "Service role can manage event bus"
ON public.event_bus
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

CREATE TABLE IF NOT EXISTS public.event_handlers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text NOT NULL,
  handler_type text NOT NULL DEFAULT 'email',
  handler_key text NOT NULL,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_handlers_event_type_check'
      AND conrelid = 'public.event_handlers'::regclass
  ) THEN
    ALTER TABLE public.event_handlers
      ADD CONSTRAINT event_handlers_event_type_check
      CHECK (
        event_type IN (
          'USER_SIGNUP',
          'USER_CONFIRMED',
          'PRODUCER_ACTIVATED',
          'BEAT_PURCHASED',
          'LICENSE_GENERATED',
          'BATTLE_WON',
          'COMMENT_RECEIVED'
        )
      );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'event_handlers_handler_type_check'
      AND conrelid = 'public.event_handlers'::regclass
  ) THEN
    ALTER TABLE public.event_handlers
      ADD CONSTRAINT event_handlers_handler_type_check
      CHECK (handler_type IN ('email'));
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS event_handlers_unique_idx
  ON public.event_handlers (event_type, handler_type, handler_key);

CREATE INDEX IF NOT EXISTS event_handlers_active_idx
  ON public.event_handlers (is_active, event_type);

ALTER TABLE public.event_handlers ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.event_handlers FROM anon;
REVOKE ALL ON TABLE public.event_handlers FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.event_handlers TO service_role;

DROP POLICY IF EXISTS "Service role can manage event handlers" ON public.event_handlers;
CREATE POLICY "Service role can manage event handlers"
ON public.event_handlers
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

INSERT INTO public.event_handlers (event_type, handler_type, handler_key, config, is_active)
VALUES
  ('USER_CONFIRMED', 'email', 'welcome_user', '{}'::jsonb, true),
  ('PRODUCER_ACTIVATED', 'email', 'producer_activation', '{}'::jsonb, true),
  ('BEAT_PURCHASED', 'email', 'purchase_receipt', '{}'::jsonb, true),
  ('LICENSE_GENERATED', 'email', 'license_ready', '{}'::jsonb, true),
  ('BATTLE_WON', 'email', 'battle_won', '{}'::jsonb, true),
  ('COMMENT_RECEIVED', 'email', 'comment_received', '{}'::jsonb, true)
ON CONFLICT (event_type, handler_type, handler_key) DO UPDATE
SET
  is_active = EXCLUDED.is_active,
  config = EXCLUDED.config,
  updated_at = now();

-- -----------------------------------------------------------------------------
-- 2) Event publish + claim helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publish_event(
  p_event_type text,
  p_user_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_payload jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_event_type text := upper(COALESCE(NULLIF(btrim(p_event_type), ''), ''));
  v_aggregate_type text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_type', '')), '');
  v_aggregate_id uuid;
  v_event_id uuid;
  v_aggregate_id_text text := NULLIF(btrim(COALESCE(v_payload->>'aggregate_id', '')), '');
BEGIN
  IF v_event_type = '' THEN
    RAISE EXCEPTION 'event_type_required';
  END IF;

  IF v_aggregate_id_text IS NOT NULL THEN
    BEGIN
      v_aggregate_id := v_aggregate_id_text::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_aggregate_id := NULL;
    END;
  END IF;

  IF v_aggregate_id IS NULL AND p_user_id IS NOT NULL
    AND v_event_type IN ('USER_SIGNUP', 'USER_CONFIRMED', 'PRODUCER_ACTIVATED') THEN
    v_aggregate_id := p_user_id;
    IF v_aggregate_type IS NULL THEN
      v_aggregate_type := 'user';
    END IF;
  END IF;

  INSERT INTO public.event_bus (
    event_type,
    aggregate_type,
    aggregate_id,
    user_id,
    payload,
    status
  )
  VALUES (
    v_event_type,
    v_aggregate_type,
    v_aggregate_id,
    p_user_id,
    v_payload,
    'pending'
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT eb.id
    INTO v_event_id
    FROM public.event_bus eb
    WHERE eb.event_type = v_event_type
      AND eb.aggregate_id IS NOT DISTINCT FROM v_aggregate_id
    ORDER BY eb.created_at DESC
    LIMIT 1;
  END IF;

  RETURN v_event_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.publish_event(text, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_event_bus_batch(
  p_limit integer DEFAULT 50,
  p_reclaim_after_seconds integer DEFAULT 600
)
RETURNS SETOF public.event_bus
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_reclaim_seconds integer := GREATEST(60, COALESCE(p_reclaim_after_seconds, 600));
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT eb.id
    FROM public.event_bus eb
    WHERE (
      eb.status = 'pending'
      OR (
        eb.status = 'processing'
        AND eb.locked_at IS NOT NULL
        AND eb.locked_at <= now() - make_interval(secs => v_reclaim_seconds)
      )
    )
      AND eb.attempts < eb.max_attempts
    ORDER BY eb.created_at ASC
    LIMIT v_limit
    FOR UPDATE SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.event_bus eb
    SET
      status = 'processing',
      locked_at = now(),
      last_error = NULL
    FROM candidates c
    WHERE eb.id = c.id
    RETURNING eb.*
  )
  SELECT *
  FROM claimed
  ORDER BY created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_event_bus_batch(integer, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_event_bus_batch(integer, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_event_bus_batch(integer, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.claim_event_bus_batch(integer, integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Triggers SQL qui publient les events
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publish_user_signup_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.publish_event(
    'USER_SIGNUP',
    NEW.id,
    jsonb_build_object(
      'aggregate_type', 'user',
      'aggregate_id', NEW.id,
      'email', lower(trim(COALESCE(NEW.email, '')))
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_publish_event ON auth.users;
CREATE TRIGGER on_auth_user_created_publish_event
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_user_signup_event();

CREATE OR REPLACE FUNCTION public.publish_user_confirmed_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
    PERFORM public.publish_event(
      'USER_CONFIRMED',
      NEW.id,
      jsonb_build_object(
        'aggregate_type', 'user',
        'aggregate_id', NEW.id,
        'email', lower(trim(COALESCE(NEW.email, ''))),
        'email_confirmed_at', NEW.email_confirmed_at
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_confirmed_publish_event ON auth.users;
CREATE TRIGGER on_auth_user_confirmed_publish_event
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW
  WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public.publish_user_confirmed_event();

CREATE OR REPLACE FUNCTION public.publish_producer_activated_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_profile jsonb := to_jsonb(NEW);
  v_old_profile jsonb := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
  v_new_account_type text := lower(COALESCE(v_new_profile->>'account_type', ''));
  v_old_account_type text := lower(COALESCE(v_old_profile->>'account_type', ''));
  v_new_role text := lower(COALESCE(v_new_profile->>'role', ''));
  v_old_role text := lower(COALESCE(v_old_profile->>'role', ''));
  v_new_is_active boolean := lower(COALESCE(v_new_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_old_is_active boolean := lower(COALESCE(v_old_profile->>'is_producer_active', 'false')) IN ('true', 't', '1', 'yes');
  v_new_is_producer boolean;
  v_old_is_producer boolean;
  v_email text;
BEGIN
  v_new_is_producer := v_new_account_type = 'producer' OR v_new_role = 'producer' OR v_new_is_active;
  v_old_is_producer := v_old_account_type = 'producer' OR v_old_role = 'producer' OR v_old_is_active;

  IF v_new_is_producer AND NOT v_old_is_producer THEN
    v_email := lower(trim(COALESCE(NEW.email, '')));
    PERFORM public.publish_event(
      'PRODUCER_ACTIVATED',
      NEW.id,
      jsonb_build_object(
        'aggregate_type', 'user_profile',
        'aggregate_id', NEW.id,
        'email', v_email,
        'role', NEW.role,
        'is_producer_active', NEW.is_producer_active
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_user_profile_producer_activated_publish_event ON public.user_profiles;
CREATE TRIGGER on_user_profile_producer_activated_publish_event
  AFTER INSERT OR UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_producer_activated_event();

CREATE OR REPLACE FUNCTION public.publish_beat_purchased_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
  SELECT lower(trim(up.email))
  INTO v_email
  FROM public.user_profiles up
  WHERE up.id = NEW.user_id;

  PERFORM public.publish_event(
    'BEAT_PURCHASED',
    NEW.user_id,
    jsonb_build_object(
      'aggregate_type', 'purchase',
      'aggregate_id', NEW.id,
      'purchase_id', NEW.id,
      'product_id', NEW.product_id,
      'producer_id', NEW.producer_id,
      'amount', NEW.amount,
      'currency', NEW.currency,
      'status', NEW.status,
      'email', COALESCE(v_email, '')
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_purchase_created_publish_event ON public.purchases;
CREATE TRIGGER on_purchase_created_publish_event
  AFTER INSERT ON public.purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_beat_purchased_event();

CREATE OR REPLACE FUNCTION public.publish_license_generated_from_purchase_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
  IF OLD.contract_pdf_path IS NULL AND NEW.contract_pdf_path IS NOT NULL THEN
    SELECT lower(trim(up.email))
    INTO v_email
    FROM public.user_profiles up
    WHERE up.id = NEW.user_id;

    PERFORM public.publish_event(
      'LICENSE_GENERATED',
      NEW.user_id,
      jsonb_build_object(
        'aggregate_type', 'purchase',
        'aggregate_id', NEW.id,
        'purchase_id', NEW.id,
        'contract_pdf_path', NEW.contract_pdf_path,
        'email', COALESCE(v_email, '')
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_purchase_contract_ready_publish_event ON public.purchases;
CREATE TRIGGER on_purchase_contract_ready_publish_event
  AFTER UPDATE OF contract_pdf_path ON public.purchases
  FOR EACH ROW
  WHEN (OLD.contract_pdf_path IS NULL AND NEW.contract_pdf_path IS NOT NULL)
  EXECUTE FUNCTION public.publish_license_generated_from_purchase_event();

CREATE OR REPLACE FUNCTION public.publish_license_generated_from_contracts_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new jsonb := to_jsonb(NEW);
  v_user_id uuid;
  v_contract_id uuid;
  v_purchase_id uuid;
  v_email text := lower(trim(COALESCE(v_new->>'email', '')));
BEGIN
  BEGIN
    v_user_id := NULLIF(btrim(COALESCE(v_new->>'user_id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_user_id := NULL;
  END;

  BEGIN
    v_contract_id := NULLIF(btrim(COALESCE(v_new->>'id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_contract_id := NULL;
  END;

  BEGIN
    v_purchase_id := NULLIF(btrim(COALESCE(v_new->>'purchase_id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_purchase_id := NULL;
  END;

  IF v_user_id IS NOT NULL AND (v_email IS NULL OR v_email = '') THEN
    SELECT lower(trim(up.email))
    INTO v_email
    FROM public.user_profiles up
    WHERE up.id = v_user_id;
  END IF;

  PERFORM public.publish_event(
    'LICENSE_GENERATED',
    v_user_id,
    jsonb_build_object(
      'aggregate_type', 'contract',
      'aggregate_id', v_contract_id,
      'contract_id', v_contract_id,
      'purchase_id', v_purchase_id,
      'email', COALESCE(v_email, '')
    )
  );

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF to_regclass('public.contracts') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS on_contract_created_publish_event ON public.contracts';
    EXECUTE '
      CREATE TRIGGER on_contract_created_publish_event
      AFTER INSERT ON public.contracts
      FOR EACH ROW
      EXECUTE FUNCTION public.publish_license_generated_from_contracts_insert()
    ';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.publish_battle_won_from_battles_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
  IF OLD.winner_id IS NULL AND NEW.winner_id IS NOT NULL THEN
    SELECT lower(trim(up.email))
    INTO v_email
    FROM public.user_profiles up
    WHERE up.id = NEW.winner_id;

    PERFORM public.publish_event(
      'BATTLE_WON',
      NEW.winner_id,
      jsonb_build_object(
        'aggregate_type', 'battle',
        'aggregate_id', NEW.id,
        'battle_id', NEW.id,
        'winner_id', NEW.winner_id,
        'votes_producer1', NEW.votes_producer1,
        'votes_producer2', NEW.votes_producer2,
        'email', COALESCE(v_email, '')
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_battle_winner_publish_event ON public.battles;
CREATE TRIGGER on_battle_winner_publish_event
  AFTER UPDATE OF winner_id ON public.battles
  FOR EACH ROW
  WHEN (OLD.winner_id IS NULL AND NEW.winner_id IS NOT NULL)
  EXECUTE FUNCTION public.publish_battle_won_from_battles_update();

CREATE OR REPLACE FUNCTION public.publish_battle_won_from_vote_result_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old jsonb := to_jsonb(OLD);
  v_new jsonb := to_jsonb(NEW);
  v_old_result text := lower(COALESCE(v_old->>'result', ''));
  v_new_result text := lower(COALESCE(v_new->>'result', ''));
  v_user_id uuid;
  v_battle_id uuid;
  v_email text;
BEGIN
  IF v_old_result = v_new_result OR v_new_result NOT IN ('won', 'winner', 'win') THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_user_id := NULLIF(btrim(COALESCE(v_new->>'winner_id', v_new->>'user_id', v_new->>'voted_for_producer_id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_user_id := NULL;
  END;

  BEGIN
    v_battle_id := NULLIF(btrim(COALESCE(v_new->>'battle_id', v_new->>'id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_battle_id := NULL;
  END;

  IF v_user_id IS NOT NULL THEN
    SELECT lower(trim(up.email))
    INTO v_email
    FROM public.user_profiles up
    WHERE up.id = v_user_id;
  END IF;

  PERFORM public.publish_event(
    'BATTLE_WON',
    v_user_id,
    jsonb_build_object(
      'aggregate_type', 'battle',
      'aggregate_id', v_battle_id,
      'battle_id', v_battle_id,
      'result', v_new_result,
      'email', COALESCE(v_email, '')
    )
  );

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF to_regclass('public.battle_votes') IS NOT NULL
     AND EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'battle_votes'
        AND column_name = 'result'
     ) THEN
    EXECUTE 'DROP TRIGGER IF EXISTS on_battle_vote_result_publish_event ON public.battle_votes';
    EXECUTE '
      CREATE TRIGGER on_battle_vote_result_publish_event
      AFTER UPDATE OF result ON public.battle_votes
      FOR EACH ROW
      EXECUTE FUNCTION public.publish_battle_won_from_vote_result_update()
    ';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.publish_comment_received_from_battle_comments_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_producer1 uuid;
  v_producer2 uuid;
  v_recipient uuid;
  v_email text;
BEGIN
  SELECT b.producer1_id, b.producer2_id
  INTO v_producer1, v_producer2
  FROM public.battles b
  WHERE b.id = NEW.battle_id;

  IF v_producer1 IS NULL AND v_producer2 IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.user_id IS NOT NULL AND NEW.user_id = v_producer1 THEN
    v_recipient := v_producer2;
  ELSIF NEW.user_id IS NOT NULL AND NEW.user_id = v_producer2 THEN
    v_recipient := v_producer1;
  ELSE
    v_recipient := v_producer1;
  END IF;

  IF v_recipient IS NULL OR v_recipient = NEW.user_id THEN
    RETURN NEW;
  END IF;

  SELECT lower(trim(up.email))
  INTO v_email
  FROM public.user_profiles up
  WHERE up.id = v_recipient;

  PERFORM public.publish_event(
    'COMMENT_RECEIVED',
    v_recipient,
    jsonb_build_object(
      'aggregate_type', 'comment',
      'aggregate_id', NEW.id,
      'comment_id', NEW.id,
      'battle_id', NEW.battle_id,
      'author_user_id', NEW.user_id,
      'email', COALESCE(v_email, '')
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_battle_comment_created_publish_event ON public.battle_comments;
CREATE TRIGGER on_battle_comment_created_publish_event
  AFTER INSERT ON public.battle_comments
  FOR EACH ROW
  EXECUTE FUNCTION public.publish_comment_received_from_battle_comments_insert();

CREATE OR REPLACE FUNCTION public.publish_comment_received_from_comments_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new jsonb := to_jsonb(NEW);
  v_user_id uuid;
  v_comment_id uuid;
  v_email text := lower(trim(COALESCE(v_new->>'email', '')));
BEGIN
  BEGIN
    v_user_id := NULLIF(btrim(COALESCE(v_new->>'recipient_user_id', v_new->>'user_id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_user_id := NULL;
  END;

  BEGIN
    v_comment_id := NULLIF(btrim(COALESCE(v_new->>'id', '')), '')::uuid;
  EXCEPTION
    WHEN invalid_text_representation THEN
      v_comment_id := NULL;
  END;

  IF v_user_id IS NOT NULL AND (v_email IS NULL OR v_email = '') THEN
    SELECT lower(trim(up.email))
    INTO v_email
    FROM public.user_profiles up
    WHERE up.id = v_user_id;
  END IF;

  PERFORM public.publish_event(
    'COMMENT_RECEIVED',
    v_user_id,
    jsonb_build_object(
      'aggregate_type', 'comment',
      'aggregate_id', v_comment_id,
      'comment_id', v_comment_id,
      'email', COALESCE(v_email, '')
    )
  );

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF to_regclass('public.comments') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS on_comment_created_publish_event ON public.comments';
    EXECUTE '
      CREATE TRIGGER on_comment_created_publish_event
      AFTER INSERT ON public.comments
      FOR EACH ROW
      EXECUTE FUNCTION public.publish_comment_received_from_comments_insert()
    ';
  END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 4) Integration email_queue (idempotence par event)
-- -----------------------------------------------------------------------------

ALTER TABLE public.email_queue
  ADD COLUMN IF NOT EXISTS source_event_id uuid REFERENCES public.event_bus(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS email_queue_source_event_unique_idx
  ON public.email_queue (source_event_id)
  WHERE source_event_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 5) Bascule vers architecture event-driven
-- -----------------------------------------------------------------------------

DROP TRIGGER IF EXISTS on_auth_user_created_enqueue_signup_email ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_confirmed_enqueue_welcome_email ON auth.users;
DROP TRIGGER IF EXISTS on_user_profile_producer_activation_email ON public.user_profiles;

-- -----------------------------------------------------------------------------
-- 6) Cron process-events (chaque minute)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_job_name text := 'process-events-every-minute';
  v_existing_job_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL OR to_regnamespace('net') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for process-events: cron/net extensions unavailable.';
    RETURN;
  END IF;

  IF to_regnamespace('vault') IS NULL THEN
    RAISE NOTICE 'Skipping cron setup for process-events: vault extension unavailable.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     OR NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key') THEN
    RAISE NOTICE 'Skipping cron setup for process-events: missing vault secrets project_url/service_role_key.';
    RETURN;
  END IF;

  SELECT jobid
  INTO v_existing_job_id
  FROM cron.job
  WHERE jobname = v_job_name
  LIMIT 1;

  IF v_existing_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_existing_job_id);
  END IF;

  PERFORM cron.schedule(
    v_job_name,
    '* * * * *',
    $cron$
      SELECT net.http_post(
        url := (
          SELECT rtrim(decrypted_secret, '/')
          FROM vault.decrypted_secrets
          WHERE name = 'project_url'
          LIMIT 1
        ) || '/functions/v1/process-events',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = 'service_role_key'
            LIMIT 1
          )
        ),
        body := '{}'::jsonb
      );
    $cron$
  );
END
$$;

COMMIT;
