BEGIN;

CREATE OR REPLACE FUNCTION private.get_public_producer_campaign_status(
  p_campaign_type text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_normalized text := lower(btrim(COALESCE(p_campaign_type, '')));
  v_type       text;
  v_is_active  boolean;
  v_max_slots  int;
BEGIN
  IF v_normalized = '' THEN
    RETURN jsonb_build_object(
      'exists', false,
      'is_active', false,
      'max_slots', null,
      'reason', 'missing_campaign_type'
    );
  END IF;

  SELECT type, is_active, max_slots
  INTO v_type, v_is_active, v_max_slots
  FROM public.producer_campaigns
  WHERE type = v_normalized;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'exists', false,
      'is_active', false,
      'max_slots', null,
      'reason', 'invalid_campaign_type'
    );
  END IF;

  RETURN jsonb_build_object(
    'exists', true,
    'type', v_type,
    'is_active', COALESCE(v_is_active, false),
    'max_slots', v_max_slots
  );
END;
$$;

REVOKE ALL ON FUNCTION private.get_public_producer_campaign_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.get_public_producer_campaign_status(text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_public_producer_campaign_status(text) IS
  'Public read-only campaign status used by the producer promo UI. Exposes existence, is_active and max_slots for a producer_campaigns row.';

COMMIT;
