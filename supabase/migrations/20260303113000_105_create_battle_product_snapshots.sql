/*
  # Battle product snapshots

  - Preserves battle product history even when the source product becomes hidden or deleted.
  - Captures a stable title + preview per battle slot.
  - Populates snapshots on assignment and on battle completion.
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.battle_product_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  battle_id uuid NOT NULL REFERENCES public.battles(id) ON DELETE CASCADE,
  slot text NOT NULL CHECK (slot IN ('producer1', 'producer2')),
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  producer_id uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  title_snapshot text,
  preview_url_snapshot text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT battle_product_snapshots_battle_slot_key UNIQUE (battle_id, slot)
);

CREATE INDEX IF NOT EXISTS idx_battle_product_snapshots_battle_id
  ON public.battle_product_snapshots (battle_id);

CREATE INDEX IF NOT EXISTS idx_battle_product_snapshots_product_id
  ON public.battle_product_snapshots (product_id)
  WHERE product_id IS NOT NULL;

ALTER TABLE public.battle_product_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view public battle product snapshots" ON public.battle_product_snapshots;
CREATE POLICY "Anyone can view public battle product snapshots"
  ON public.battle_product_snapshots
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.battles b
      WHERE b.id = battle_product_snapshots.battle_id
        AND b.status IN ('active', 'voting', 'completed')
    )
  );

DROP POLICY IF EXISTS "Participants can view own battle product snapshots" ON public.battle_product_snapshots;
CREATE POLICY "Participants can view own battle product snapshots"
  ON public.battle_product_snapshots
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.battles b
      WHERE b.id = battle_product_snapshots.battle_id
        AND (b.producer1_id = auth.uid() OR b.producer2_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "Admins can view all battle product snapshots" ON public.battle_product_snapshots;
CREATE POLICY "Admins can view all battle product snapshots"
  ON public.battle_product_snapshots
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

REVOKE INSERT, UPDATE, DELETE ON TABLE public.battle_product_snapshots FROM anon, authenticated;
GRANT SELECT ON TABLE public.battle_product_snapshots TO anon, authenticated;
GRANT ALL ON TABLE public.battle_product_snapshots TO service_role;

DROP TRIGGER IF EXISTS update_battle_product_snapshots_updated_at ON public.battle_product_snapshots;
CREATE TRIGGER update_battle_product_snapshots_updated_at
  BEFORE UPDATE ON public.battle_product_snapshots
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.upsert_battle_product_snapshot(
  p_battle_id uuid,
  p_slot text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_battle public.battles%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_product_id uuid;
  v_producer_id uuid;
BEGIN
  IF p_slot NOT IN ('producer1', 'producer2') THEN
    RAISE EXCEPTION 'invalid_battle_snapshot_slot';
  END IF;

  SELECT *
  INTO v_battle
  FROM public.battles
  WHERE id = p_battle_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'battle_not_found';
  END IF;

  IF p_slot = 'producer1' THEN
    v_product_id := v_battle.product1_id;
    v_producer_id := v_battle.producer1_id;
  ELSE
    v_product_id := v_battle.product2_id;
    v_producer_id := v_battle.producer2_id;
  END IF;

  IF v_product_id IS NULL THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = v_product_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  INSERT INTO public.battle_product_snapshots (
    battle_id,
    slot,
    product_id,
    producer_id,
    title_snapshot,
    preview_url_snapshot
  )
  VALUES (
    p_battle_id,
    p_slot,
    v_product.id,
    COALESCE(v_product.producer_id, v_producer_id),
    NULLIF(btrim(COALESCE(v_product.title, '')), ''),
    NULLIF(btrim(COALESCE(v_product.preview_url, '')), '')
  )
  ON CONFLICT (battle_id, slot)
  DO UPDATE
  SET
    product_id = COALESCE(EXCLUDED.product_id, battle_product_snapshots.product_id),
    producer_id = COALESCE(EXCLUDED.producer_id, battle_product_snapshots.producer_id),
    title_snapshot = COALESCE(EXCLUDED.title_snapshot, battle_product_snapshots.title_snapshot),
    preview_url_snapshot = COALESCE(EXCLUDED.preview_url_snapshot, battle_product_snapshots.preview_url_snapshot),
    updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.capture_battle_product_snapshots()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.product1_id IS NOT NULL THEN
      PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer1');
    END IF;

    IF NEW.product2_id IS NOT NULL THEN
      PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer2');
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.product1_id IS DISTINCT FROM OLD.product1_id THEN
    PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer1');
  END IF;

  IF NEW.product2_id IS DISTINCT FROM OLD.product2_id THEN
    PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer2');
  END IF;

  IF NEW.status = 'completed' AND COALESCE(OLD.status::text, '') <> 'completed' THEN
    PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer1');
    PERFORM public.upsert_battle_product_snapshot(NEW.id, 'producer2');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_capture_battle_product_snapshots ON public.battles;
CREATE TRIGGER trg_capture_battle_product_snapshots
  AFTER INSERT OR UPDATE OF product1_id, product2_id, status
  ON public.battles
  FOR EACH ROW
  EXECUTE FUNCTION public.capture_battle_product_snapshots();

DO $$
DECLARE
  v_battle_id uuid;
BEGIN
  FOR v_battle_id IN
    SELECT b.id
    FROM public.battles b
    WHERE b.product1_id IS NOT NULL
       OR b.product2_id IS NOT NULL
       OR b.status = 'completed'
  LOOP
    PERFORM public.upsert_battle_product_snapshot(v_battle_id, 'producer1');
    PERFORM public.upsert_battle_product_snapshot(v_battle_id, 'producer2');
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.upsert_battle_product_snapshot(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.upsert_battle_product_snapshot(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.upsert_battle_product_snapshot(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_battle_product_snapshot(uuid, text) TO service_role;

COMMIT;
