-- Sync products.play_count from user_interactions (action_type = 'play')
-- Adds an AFTER INSERT trigger that increments products.play_count whenever a
-- 'play' interaction is logged, and backfills the column from existing rows.

CREATE OR REPLACE FUNCTION public.tg_user_interactions_increment_play_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.action_type = 'play' AND NEW.beat_id IS NOT NULL THEN
    UPDATE public.products
    SET play_count = COALESCE(play_count, 0) + 1
    WHERE id = NEW.beat_id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.tg_user_interactions_increment_play_count() FROM PUBLIC;

DROP TRIGGER IF EXISTS user_interactions_increment_play_count
  ON public.user_interactions;

CREATE TRIGGER user_interactions_increment_play_count
AFTER INSERT ON public.user_interactions
FOR EACH ROW
WHEN (NEW.action_type = 'play')
EXECUTE FUNCTION public.tg_user_interactions_increment_play_count();

-- Backfill: rebuild play_count from existing 'play' interactions.
-- Safe to overwrite because no other writer currently bumps play_count.
WITH play_aggregates AS (
  SELECT beat_id, COUNT(*)::int AS play_total
  FROM public.user_interactions
  WHERE action_type = 'play'
  GROUP BY beat_id
)
UPDATE public.products p
SET play_count = pa.play_total
FROM play_aggregates pa
WHERE p.id = pa.beat_id;
