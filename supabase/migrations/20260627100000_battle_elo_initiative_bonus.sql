/*
  # Battle : bonus ELO « d'initiative » pour le demandeur (producer1)

  Étend la migration 20260625100000 (pénalités ELO refus / non-réponse).

  Nouveauté : quand producer2 (l'invité) est RÉELLEMENT pénalisé, producer1
  (le demandeur) reçoit un bonus ELO « d'initiative », sous le MÊME verrou et le
  MÊME flag d'idempotence (battles.penalty_applied) que la pénalité.

    refus    (respond_to_battle)                : P2 -5 ELO, P1 +2 ELO
    expiry   (expire_pending_battle_invitations) : P2 -8 ELO, P1 +3 ELO
    admin cancel                                  : aucun changement ELO (inchangé,
                                                    admin_cancel_battle n'appelle pas le helper)

  Garanties (toutes sous le verrou FOR UPDATE du helper) :
    - P2 pénalisé  <=>  P1 récompensé   (sauf gardes P1 NULL ou P1 = P2)
    - jamais deux applications de pénalité OU de bonus sur la même battle
    - aucun bonus si producer1_id est NULL
    - aucun bonus si producer1_id = producer2_id (sécurité)
    - plancher ELO à 100 conservé (identique à update_elo_rating)

  engagement_score : NON modifié ici (le -2 par refus reste géré séparément).
  Système victoire/défaite classique : INCHANGÉ.

  Helper unifié : private.apply_battle_elo_penalty(p_battle_id, p_reason).
  La signature passe de 4 args à 2 args. Les points P2/P1 sont dérivés d'un SEUL
  CASE (source unique de vérité — pas de duplication entre refus et expiration).
  Le helper n'avait qu'un seul appelant interne, le changement de signature est sûr.

  Dépend de 20260625100000 (colonnes penalty_*, helper, fonctions refactorées).
*/

BEGIN;

-- 1) Colonnes de récompense (audit + idempotence partagée) ------------------------
ALTER TABLE public.battles
  ADD COLUMN IF NOT EXISTS reward_points      integer,
  ADD COLUMN IF NOT EXISTS reward_producer_id uuid REFERENCES public.user_profiles(id);

COMMENT ON COLUMN public.battles.reward_points IS
  'Points ELO « bonus d''initiative » accordés à producer1 quand producer2 est pénalisé (2 sur refus, 3 sur expiration).';
COMMENT ON COLUMN public.battles.reward_producer_id IS
  'Producteur ayant reçu le bonus ELO d''initiative (toujours producer1).';

-- 2) Helper unifié : pénalité P2 + bonus P1, idempotent par battle ----------------
--    Remplace la version 4-args de 20260625100000. Source UNIQUE des points.
DROP FUNCTION IF EXISTS private.apply_battle_elo_penalty(uuid, uuid, integer, text);

CREATE OR REPLACE FUNCTION private.apply_battle_elo_penalty(
  p_battle_id uuid,
  p_reason    text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_already        boolean;
  v_producer1      uuid;     -- demandeur (récompensé)
  v_producer2      uuid;     -- invité    (pénalisé)
  v_title          text;
  v_penalty_points integer;
  v_reward_points  integer;
  v_reward_done    boolean := false;
  v_msg            text;
BEGIN
  -- Source UNIQUE des points par raison. Ajouter une raison = une ligne ici.
  CASE p_reason
    WHEN 'refusal' THEN v_penalty_points := 5; v_reward_points := 2;
    WHEN 'expiry'  THEN v_penalty_points := 8; v_reward_points := 3;
    ELSE RETURN false;                         -- raison inconnue : on ne touche à rien
  END CASE;

  -- Verrouille la ligne battle + lit le flag d'idempotence et les 2 producteurs.
  SELECT penalty_applied,
         producer1_id,
         producer2_id,
         COALESCE(NULLIF(trim(title), ''), 'Battle')
  INTO v_already, v_producer1, v_producer2, v_title
  FROM public.battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF v_already IS DISTINCT FROM false THEN
    RETURN false;                              -- déjà traitée OU battle introuvable
  END IF;

  IF v_producer2 IS NULL THEN
    RETURN false;                              -- pas d'invité à pénaliser
  END IF;

  -- a) Pénalité P2 : même plancher (100) que update_elo_rating.
  UPDATE public.user_profiles
  SET elo_rating = GREATEST(100, COALESCE(elo_rating, 1200) - v_penalty_points),
      updated_at = now()
  WHERE id = v_producer2;

  -- b) Bonus P1 : seulement si P1 existe ET n'est pas P2 (sécurité). Pas de cap haut.
  IF v_producer1 IS NOT NULL AND v_producer1 IS DISTINCT FROM v_producer2 THEN
    UPDATE public.user_profiles
    SET elo_rating = COALESCE(elo_rating, 1200) + v_reward_points,
        updated_at = now()
    WHERE id = v_producer1;
    v_reward_done := true;
  END IF;

  -- c) Marque la battle : pénalité ET bonus partagent le même flag d'idempotence.
  UPDATE public.battles
  SET penalty_applied       = true,
      penalty_type          = p_reason,
      penalty_points        = v_penalty_points,
      penalized_producer_id = v_producer2,
      reward_points         = CASE WHEN v_reward_done THEN v_reward_points ELSE NULL END,
      reward_producer_id    = CASE WHEN v_reward_done THEN v_producer1     ELSE NULL END,
      updated_at            = now()
  WHERE id = p_battle_id;

  -- d) Notification in-app du bonus pour P1 (FR, cohérente avec l'existant).
  --    Émise UNIQUEMENT quand le bonus est réellement accordé.
  IF v_reward_done THEN
    v_msg := CASE p_reason
      WHEN 'refusal' THEN format(
        'Ta demande de battle "%s" a été refusée. Tu reçois un bonus d''initiative de +%s points de classement.',
        v_title, v_reward_points)
      WHEN 'expiry' THEN format(
        'Ta demande de battle "%s" a expiré sans réponse dans le délai de 7 jours. Tu reçois un bonus d''initiative de +%s points de classement.',
        v_title, v_reward_points)
    END;

    BEGIN
      INSERT INTO public.notifications (user_id, type, title, message)
      VALUES (v_producer1, 'battle_initiative_bonus', 'Bonus d''initiative', v_msg);
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'battle initiative-bonus notification failed for battle %: %', p_battle_id, SQLERRM;
    END;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION private.apply_battle_elo_penalty(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.apply_battle_elo_penalty(uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION private.apply_battle_elo_penalty(uuid, text) TO service_role;

-- 3) respond_to_battle : pénalité+bonus sur la branche refus ----------------------
--    Recréation à l'identique de 20260625100000 ; seul l'appel du helper change.
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

    PERFORM public.recalculate_engagement(v_actor);                 -- conservé (engagement -2)
    PERFORM private.apply_battle_elo_penalty(p_battle_id, 'refusal'); -- P2 -5 ELO, P1 +2 ELO
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) TO authenticated;

-- 4) Sweep d'expiration : pénalité+bonus avant l'annulation -----------------------
--    Recréation à l'identique de 20260625100000 ; seul l'appel du helper change.
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

  -- P2 -8 ELO (non-réponse) + P1 +3 ELO (bonus), idempotent par battle.
  -- Le helper dérive lui-même producer1/producer2 depuis la ligne battle.
  FOR v_rec IN
    SELECT id
    FROM public.battles
    WHERE id = ANY (v_ids)
  LOOP
    PERFORM private.apply_battle_elo_penalty(v_rec.id, 'expiry');
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
