/*
  # Fix battle completed reputation trigger enum cast

  Problem:
  - `public.on_battle_completed_reputation()` compared `OLD.status` to an empty
    string via `COALESCE(OLD.status, '')`.
  - `public.battle_status` is an enum, so `''` is an invalid enum value.
  - Any `UPDATE public.battles` hitting this trigger could fail with:
      `22P02 invalid input value for enum battle_status: ""`

  Fix:
  - Compare the previous status as text, like the snapshot trigger already does.
  - Keep behavior unchanged: only fire reputation writes on transition into
    `completed`.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.on_battle_completed_reputation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND COALESCE(OLD.status::text, '') <> 'completed' THEN
    PERFORM public.apply_reputation_event_internal(
      p_user_id => NEW.producer1_id,
      p_source => 'battles',
      p_event_type => 'battle_participation',
      p_entity_type => 'battle',
      p_entity_id => NEW.id,
      p_delta => NULL,
      p_metadata => jsonb_build_object(
        'battle_id', NEW.id,
        'role', 'producer1'
      ),
      p_idempotency_key => 'battle_participation:' || NEW.id::text || ':' || NEW.producer1_id::text
    );

    IF NEW.producer2_id IS NOT NULL THEN
      PERFORM public.apply_reputation_event_internal(
        p_user_id => NEW.producer2_id,
        p_source => 'battles',
        p_event_type => 'battle_participation',
        p_entity_type => 'battle',
        p_entity_id => NEW.id,
        p_delta => NULL,
        p_metadata => jsonb_build_object(
          'battle_id', NEW.id,
          'role', 'producer2'
        ),
        p_idempotency_key => 'battle_participation:' || NEW.id::text || ':' || NEW.producer2_id::text
      );
    END IF;

    IF NEW.winner_id IS NOT NULL THEN
      PERFORM public.apply_reputation_event_internal(
        p_user_id => NEW.winner_id,
        p_source => 'battles',
        p_event_type => 'battle_won',
        p_entity_type => 'battle',
        p_entity_id => NEW.id,
        p_delta => NULL,
        p_metadata => jsonb_build_object(
          'battle_id', NEW.id,
          'winner_id', NEW.winner_id
        ),
        p_idempotency_key => 'battle_won:' || NEW.id::text || ':' || NEW.winner_id::text
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;
