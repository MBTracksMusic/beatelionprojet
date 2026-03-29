/*
  # Make purchase-related event triggers non-blocking

  Why:
  - Purchase completion must never be rolled back by email/event pipeline failures.
  - Production showed `complete_standard_purchase` failing because a downstream
    `email_queue` FK violation bubbled up during purchase completion.

  What:
  - Harden purchase and license event triggers so they swallow side-effect
    failures and only emit SQL notices for diagnostics.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.publish_beat_purchased_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
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
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'publish_beat_purchased_event failed for purchase_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_license_generated_from_purchase_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text;
BEGIN
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
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'publish_license_generated_from_purchase_event failed for purchase_id=%: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

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
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'publish_license_generated_from_contracts_insert failed for contract_id=%: %',
        COALESCE((v_new->>'id'), '<null>'),
        SQLERRM;
  END;

  RETURN NEW;
END;
$$;

COMMIT;
