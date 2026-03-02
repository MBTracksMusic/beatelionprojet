/*
  # Harden product history guards for terminated battles

  - Treats completed battles like immutable sales history for beat edits.
  - Blocks hard delete when a product has completed purchases or completed battles.
  - Keeps existing active-battle audio lock behavior unchanged.
*/

BEGIN;

CREATE INDEX IF NOT EXISTS idx_battles_product1_completed
  ON public.battles (product1_id)
  WHERE status = 'completed' AND product1_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_battles_product2_completed
  ON public.battles (product2_id)
  WHERE status = 'completed' AND product2_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.product_has_terminated_battle(p_product_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.battles b
    WHERE b.status = 'completed'
      AND (
        b.product1_id = p_product_id
        OR b.product2_id = p_product_id
      )
  );
$$;

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
  v_has_terminated_battle boolean := false;
  v_can_edit_audio boolean := false;
  v_can_edit_metadata_essentials boolean := false;
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

  v_has_terminated_battle := public.product_has_terminated_battle(p_product_id);
  v_can_edit_audio := v_sales_count = 0 AND v_active_battle_count = 0 AND NOT v_has_terminated_battle;
  v_can_edit_metadata_essentials := v_sales_count = 0 AND NOT v_has_terminated_battle;

  RETURN jsonb_build_object(
    'can_edit_audio', v_can_edit_audio,
    'can_edit_metadata', v_can_edit_metadata_essentials,
    'can_edit_metadata_essentials', v_can_edit_metadata_essentials,
    'must_create_new_version', v_sales_count > 0 OR v_has_terminated_battle,
    'has_sales', v_sales_count > 0,
    'has_active_battle', v_active_battle_count > 0,
    'has_terminated_battle', v_has_terminated_battle
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
  v_has_terminated_battle boolean := false;
  v_audio_changed boolean := false;
  v_metadata_essentials_changed boolean := false;
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

  v_has_terminated_battle := public.product_has_terminated_battle(OLD.id);

  v_audio_changed := NEW.master_path IS DISTINCT FROM OLD.master_path
    OR NEW.master_url IS DISTINCT FROM OLD.master_url
    OR NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds
    OR NEW.file_format IS DISTINCT FROM OLD.file_format;

  v_metadata_essentials_changed := NEW.title IS DISTINCT FROM OLD.title
    OR NEW.description IS DISTINCT FROM OLD.description
    OR NEW.price IS DISTINCT FROM OLD.price
    OR NEW.bpm IS DISTINCT FROM OLD.bpm
    OR NEW.key_signature IS DISTINCT FROM OLD.key_signature
    OR NEW.cover_image_url IS DISTINCT FROM OLD.cover_image_url
    OR NEW.genre_id IS DISTINCT FROM OLD.genre_id
    OR NEW.mood_id IS DISTINCT FROM OLD.mood_id
    OR NEW.tags IS DISTINCT FROM OLD.tags
    OR NEW.license_terms IS DISTINCT FROM OLD.license_terms;

  IF v_sales_count > 0 AND (v_audio_changed OR v_metadata_essentials_changed) THEN
    RAISE EXCEPTION 'product_must_create_new_version';
  END IF;

  IF v_has_terminated_battle AND v_audio_changed THEN
    RAISE EXCEPTION 'product_audio_locked_by_terminated_battle';
  END IF;

  IF v_has_terminated_battle AND v_metadata_essentials_changed THEN
    RAISE EXCEPTION 'product_metadata_locked_by_terminated_battle';
  END IF;

  IF v_active_battle_count > 0 AND v_audio_changed THEN
    RAISE EXCEPTION 'product_audio_locked_by_active_battle';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_product_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sales_count integer := 0;
  v_has_terminated_battle boolean := false;
BEGIN
  SELECT COUNT(*)
  INTO v_sales_count
  FROM public.purchases pu
  WHERE pu.product_id = OLD.id
    AND pu.status IN ('completed', 'refunded');

  IF OLD.product_type = 'beat' THEN
    v_has_terminated_battle := public.product_has_terminated_battle(OLD.id);
  END IF;

  IF v_sales_count > 0 THEN
    RAISE EXCEPTION 'product_has_sales';
  END IF;

  IF v_has_terminated_battle THEN
    RAISE EXCEPTION 'product_has_terminated_battle';
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS guard_product_hard_delete_trigger ON public.products;
CREATE TRIGGER guard_product_hard_delete_trigger
  BEFORE DELETE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_product_hard_delete();

CREATE OR REPLACE FUNCTION public.rpc_delete_product_if_no_sales(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_product public.products%ROWTYPE;
  v_sales_count integer := 0;
  v_has_terminated_battle boolean := false;
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

  IF v_sales_count > 0 THEN
    RAISE EXCEPTION 'product_has_sales';
  END IF;

  v_has_terminated_battle := public.product_has_terminated_battle(p_product_id);

  IF v_has_terminated_battle THEN
    RAISE EXCEPTION 'product_has_terminated_battle';
  END IF;

  DELETE FROM public.products
  WHERE id = p_product_id
    AND producer_id = v_actor;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'delete_failed';
  END IF;

  RETURN jsonb_build_object(
    'deleted', true,
    'product_id', v_product.id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.product_has_terminated_battle(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.product_has_terminated_battle(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.product_has_terminated_battle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.product_has_terminated_battle(uuid) TO service_role;

COMMIT;
