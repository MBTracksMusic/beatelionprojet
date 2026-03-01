/*
  # Product editability rules

  - Adds can_edit_product(product_id) RPC.
  - Enforces product edit restrictions at DB level.
  - Keeps producer UPDATE policy aligned with real sales history.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.can_edit_product(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_sales_count integer := 0;
  v_active_battle_count integer := 0;
BEGIN
  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id
    AND product_type = 'beat'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;

  IF v_actor IS NULL OR v_product.producer_id <> v_actor THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = p_product_id
    AND pu.status IN ('completed', 'refunded');

  SELECT COUNT(*)
  INTO v_active_battle_count
  FROM public.battles b
  WHERE b.status = 'active'
    AND (b.product1_id = p_product_id OR b.product2_id = p_product_id);

  RETURN jsonb_build_object(
    'can_edit_audio', v_sales_count = 0 AND v_active_battle_count = 0,
    'can_edit_metadata', v_sales_count = 0,
    'must_create_new_version', v_sales_count > 0
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_product_editability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sales_count integer := 0;
  v_active_battle_count integer := 0;
  v_audio_changed boolean := false;
  v_metadata_changed boolean := false;
BEGIN
  IF TG_OP <> 'UPDATE' OR OLD.product_type <> 'beat' THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = OLD.id
    AND pu.status IN ('completed', 'refunded');

  SELECT COUNT(*)
  INTO v_active_battle_count
  FROM public.battles b
  WHERE b.status = 'active'
    AND (b.product1_id = OLD.id OR b.product2_id = OLD.id);

  v_audio_changed := NEW.master_path IS DISTINCT FROM OLD.master_path
    OR NEW.master_url IS DISTINCT FROM OLD.master_url
    OR NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds
    OR NEW.file_format IS DISTINCT FROM OLD.file_format;

  v_metadata_changed := NEW.title IS DISTINCT FROM OLD.title
    OR NEW.description IS DISTINCT FROM OLD.description
    OR NEW.price IS DISTINCT FROM OLD.price
    OR NEW.bpm IS DISTINCT FROM OLD.bpm
    OR NEW.key_signature IS DISTINCT FROM OLD.key_signature
    OR NEW.cover_image_url IS DISTINCT FROM OLD.cover_image_url
    OR NEW.genre_id IS DISTINCT FROM OLD.genre_id
    OR NEW.mood_id IS DISTINCT FROM OLD.mood_id
    OR NEW.tags IS DISTINCT FROM OLD.tags
    OR NEW.license_terms IS DISTINCT FROM OLD.license_terms;

  IF v_sales_count > 0 AND (v_audio_changed OR v_metadata_changed) THEN
    RAISE EXCEPTION 'product_must_create_new_version';
  END IF;

  IF v_active_battle_count > 0 AND v_audio_changed THEN
    RAISE EXCEPTION 'product_audio_locked_by_active_battle';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_product_editability_trigger ON public.products;
CREATE TRIGGER guard_product_editability_trigger
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_product_editability();

DROP POLICY IF EXISTS "Producers can update own unsold products" ON public.products;
CREATE POLICY "Producers can update own unsold products"
  ON public.products
  FOR UPDATE
  TO authenticated
  USING (
    producer_id = auth.uid()
    AND deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.status IN ('completed', 'refunded')
    )
  )
  WITH CHECK (
    producer_id = auth.uid()
    AND deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.is_producer_active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.purchases pu
      WHERE pu.product_id = products.id
        AND pu.status IN ('completed', 'refunded')
    )
    AND (
      NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
      OR public.can_publish_beat(auth.uid(), id)
    )
  );

REVOKE EXECUTE ON FUNCTION public.can_edit_product(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_edit_product(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_edit_product(uuid) TO service_role;

COMMIT;
