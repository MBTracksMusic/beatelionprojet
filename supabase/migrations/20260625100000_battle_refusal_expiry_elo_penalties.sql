/*
  # Battle: pénalités ELO sur refus / non-réponse

  - Refus d'une invitation : producteur 2 perd 5 points ELO.
  - Non-réponse après 7 jours (sweep d'expiration) : producteur 2 perd 8 points ELO.
  - Défaite normale : INCHANGÉE (logique ELO existante, ~-16 à match égal).
  - engagement_score : NON modifié ici (le -2 par refus existant est conservé).
  - Le producteur qui lance la battle (producer1) n'est jamais pénalisé.

  Idempotence : colonne battles.penalty_applied + helper qui verrouille la ligne.
  Une pénalité ne peut donc jamais être appliquée deux fois pour la même battle.

  Dépend de 20260624071000 (sweep d'expiration) et 20260624120000 (respond_to_battle 4-args).
*/

BEGIN;

-- 1) Colonnes d'idempotence / audit -----------------------------------------------
ALTER TABLE public.battles
  ADD COLUMN IF NOT EXISTS penalty_applied       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS penalty_type          text,      -- 'refusal' | 'expiry'
  ADD COLUMN IF NOT EXISTS penalty_points        integer,   -- 5 | 8
  ADD COLUMN IF NOT EXISTS penalized_producer_id uuid REFERENCES public.user_profiles(id);

COMMENT ON COLUMN public.battles.penalty_applied IS
  'True une fois qu''une pénalité ELO (refus/expiration) a été appliquée à cette battle (garde d''idempotence).';
COMMENT ON COLUMN public.battles.penalty_type IS 'refusal | expiry — quelle pénalité a été appliquée.';
COMMENT ON COLUMN public.battles.penalty_points IS 'Nombre de points ELO retirés (5 ou 8).';
COMMENT ON COLUMN public.battles.penalized_producer_id IS 'Producteur ayant perdu de l''ELO pour cette battle (toujours producer2).';

-- 2) Helper de pénalité ELO, idempotent par battle --------------------------------
CREATE OR REPLACE FUNCTION private.apply_battle_elo_penalty(
  p_battle_id   uuid,
  p_producer_id uuid,
  p_points      integer,
  p_type        text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_already boolean;
BEGIN
  IF p_producer_id IS NULL OR p_points IS NULL OR p_points <= 0 THEN
    RETURN false;
  END IF;

  -- Verrouille la ligne battle + lit le flag d'idempotence d'un coup.
  SELECT penalty_applied INTO v_already
  FROM public.battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF v_already IS DISTINCT FROM false THEN
    RETURN false;                       -- déjà pénalisée OU battle introuvable
  END IF;

  -- Retire l'ELO avec le même plancher (100) que update_elo_rating.
  UPDATE public.user_profiles
  SET elo_rating = GREATEST(100, COALESCE(elo_rating, 1200) - p_points),
      updated_at = now()
  WHERE id = p_producer_id;

  -- Marque la battle pour que la pénalité ne soit jamais appliquée deux fois.
  UPDATE public.battles
  SET penalty_applied       = true,
      penalty_type          = p_type,
      penalty_points        = p_points,
      penalized_producer_id = p_producer_id,
      updated_at            = now()
  WHERE id = p_battle_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.apply_battle_elo_penalty(uuid, uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.apply_battle_elo_penalty(uuid, uuid, integer, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION private.apply_battle_elo_penalty(uuid, uuid, integer, text) TO service_role;

-- 3) respond_to_battle : -5 ELO sur la branche refus ------------------------------
--    (recréation à l'identique de la version 20260624120000 + la ligne de pénalité)
CREATE OR REPLACE FUNCTION public.respond_to_battle(
  p_battle_id   uuid,
  p_accept      boolean,
  p_reason      text DEFAULT NULL,
  p_product2_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_battle public.battles%ROWTYPE;
  v_reason text := NULLIF(trim(COALESCE(p_reason, '')), '');
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'auth_required';
  END IF;

  SELECT * INTO v_battle
  FROM public.battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'battle_not_found';
  END IF;

  IF v_battle.producer2_id IS NULL OR v_battle.producer2_id != v_actor THEN
    RAISE EXCEPTION 'only_invited_producer_can_respond';
  END IF;

  IF v_battle.status != 'pending_acceptance' THEN
    RAISE EXCEPTION 'battle_not_waiting_for_response';
  END IF;

  IF v_battle.accepted_at IS NOT NULL OR v_battle.rejected_at IS NOT NULL THEN
    RAISE EXCEPTION 'response_already_recorded';
  END IF;

  IF p_accept THEN
    -- Beat désormais obligatoire pour accepter
    IF p_product2_id IS NULL THEN
      RAISE EXCEPTION 'BATTLE_PRODUCT2_REQUIRED' USING ERRCODE = 'P0001';
    END IF;

    -- Cohérence de genre avec la battle
    IF NOT public.is_battle_product_genre_match(p_product2_id, v_battle.genre_id) THEN
      RAISE EXCEPTION 'BATTLE_PRODUCT2_GENRE_MISMATCH'
        USING ERRCODE = 'P0001',
              DETAIL = jsonb_build_object('product2_id', p_product2_id, 'genre_id', v_battle.genre_id)::text;
    END IF;

    -- Rejoue exactement la validation admin (producteurs actifs, écart Elo,
    -- les 2 beats requis + éligibles). product2 est vérifié pour v_actor.
    PERFORM public.assert_battle_create_validations(
      v_battle.producer1_id,
      v_actor,
      v_battle.product1_id,
      p_product2_id,
      true,
      400
    );

    -- Cap mensuel produit (exclut la battle courante du décompte)
    PERFORM public.assert_battle_product_monthly_caps(
      NULL,
      p_product2_id,
      p_battle_id
    );

    -- Attache le beat + avance. Le trigger trg_sync_battle_product_locks_write
    -- se déclenche ici et lève BATTLE_PRODUCT_ALREADY_OCCUPIED si déjà engagé.
    UPDATE public.battles
    SET product2_id = p_product2_id,
        status = 'awaiting_admin',
        accepted_at = now(),
        rejected_at = NULL,
        rejection_reason = NULL,
        updated_at = now()
    WHERE id = p_battle_id;
  ELSE
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;

    IF NOT public.check_daily_battle_refusals(v_actor) THEN
      RAISE EXCEPTION 'Daily battle refusal limit reached (5 per day)';
    END IF;

    UPDATE public.battles
    SET status = 'rejected',
        rejected_at = now(),
        accepted_at = NULL,
        rejection_reason = v_reason,
        updated_at = now()
    WHERE id = p_battle_id;

    UPDATE public.user_profiles
    SET battle_refusal_count = COALESCE(battle_refusal_count, 0) + 1,
        updated_at = now()
    WHERE id = v_actor;

    PERFORM public.recalculate_engagement(v_actor);                       -- conservé (engagement -2)
    PERFORM private.apply_battle_elo_penalty(p_battle_id, v_actor, 5, 'refusal');  -- NOUVEAU : ELO -5
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) TO authenticated;

-- 4) Sweep d'expiration : -8 ELO au producteur 2 avant l'annulation ---------------
--    (recréation à l'identique de 20260624071000 + boucle de pénalité)
CREATE OR REPLACE FUNCTION private.expire_pending_battle_invitations(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 500), 1000));
  v_ids   uuid[];
  v_count integer := 0;
  v_rec   record;
BEGIN
  SELECT array_agg(id)
  INTO v_ids
  FROM (
    SELECT id
    FROM public.battles
    WHERE status = 'pending_acceptance'
      AND response_deadline IS NOT NULL
      AND response_deadline <= now()
    ORDER BY response_deadline ASC
    LIMIT v_limit
  ) s;

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  -- NOUVEAU : -8 ELO au producteur qui n'a pas répondu (producer2), idempotent par battle.
  FOR v_rec IN
    SELECT id, producer2_id
    FROM public.battles
    WHERE id = ANY (v_ids)
  LOOP
    PERFORM private.apply_battle_elo_penalty(v_rec.id, v_rec.producer2_id, 8, 'expiry');
  END LOOP;

  UPDATE public.battles
  SET status = 'cancelled',
      rejection_reason = COALESCE(NULLIF(btrim(rejection_reason), ''), 'auto_expired_no_response'),
      updated_at = now()
  WHERE id = ANY (v_ids)
    AND status = 'pending_acceptance';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

COMMIT;
