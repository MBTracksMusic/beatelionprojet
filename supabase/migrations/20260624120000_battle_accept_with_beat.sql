/*
  # Battle: accepter avec son beat (producteur 2)

  - Helper is_battle_product_genre_match : cohérence de genre d'un beat vs la battle.
  - private.rpc_create_battle : product1 (beat du créateur) devient obligatoire ;
    product1 (et product2 s'il est fourni) doivent être du genre de la battle.
  - public.respond_to_battle : nouveau paramètre p_product2_id. Sur accept, le beat
    est obligatoire, validé (éligibilité, genre, validation admin complète, cap mensuel)
    puis attaché ; le trigger de lock garantit l'anti-occupation. Refus inchangé.

  Dépend de 20260624073000 (version canonique de assert_battle_create_validations).
*/

BEGIN;

-- 1) Helper de cohérence de genre -------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_battle_product_genre_match(
  p_product_id uuid,
  p_genre_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_genre_id IS NULL
    OR EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = p_product_id
        AND p.genre_id = p_genre_id
    );
$$;

REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) TO service_role;

-- 2) Création : product1 obligatoire + cohérence genre ----------------------------
CREATE OR REPLACE FUNCTION private.rpc_create_battle(
  p_title         text,
  p_slug          text,
  p_producer2_id  uuid,
  p_description   text DEFAULT NULL,
  p_product1_id   uuid DEFAULT NULL,
  p_product2_id   uuid DEFAULT NULL,
  p_battle_type   text DEFAULT 'user',
  p_genre_id      uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor          uuid := auth.uid();
  v_title          text := NULLIF(trim(COALESCE(p_title, '')), '');
  v_slug           text := NULLIF(trim(COALESCE(p_slug, '')), '');
  v_description    text := NULLIF(trim(COALESCE(p_description, '')), '');
  v_cooldown_days  integer;
  v_cooldown_end   timestamptz;
  v_new_battle_id  uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  IF v_title IS NULL THEN
    RAISE EXCEPTION 'title_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_slug IS NULL THEN
    RAISE EXCEPTION 'slug_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_battle_type IS NULL OR p_battle_type NOT IN ('user') THEN
    RAISE EXCEPTION 'unsupported_battle_type' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.is_battle_genre_eligible(p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_GENRE_INVALID'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('genre_id', p_genre_id)::text;
  END IF;

  -- product1 (beat du créateur) obligatoire
  IF p_product1_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  -- cohérence de genre du beat du créateur
  IF NOT public.is_battle_product_genre_match(p_product1_id, p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_GENRE_MISMATCH'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('product1_id', p_product1_id, 'genre_id', p_genre_id)::text;
  END IF;

  -- product2 reste optionnel à la création, mais s'il est fourni il doit matcher le genre
  IF p_product2_id IS NOT NULL
     AND NOT public.is_battle_product_genre_match(p_product2_id, p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT2_GENRE_MISMATCH'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('product2_id', p_product2_id, 'genre_id', p_genre_id)::text;
  END IF;

  PERFORM public.assert_battle_create_validations(
    v_actor,
    p_producer2_id,
    p_product1_id,
    p_product2_id,
    false,
    400
  );

  PERFORM public.assert_battle_product_monthly_caps(
    p_product1_id,
    p_product2_id,
    NULL
  );

  v_cooldown_days := public.get_battle_pair_cooldown_days(p_battle_type);

  IF NOT public.can_create_battle(v_actor) THEN
    RAISE EXCEPTION 'BATTLE_QUOTA_REACHED' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.can_create_active_battle(v_actor) THEN
    RAISE EXCEPTION 'BATTLE_ACTIVE_CAP_REACHED' USING ERRCODE = 'P0001';
  END IF;

  IF public.check_battle_pair_active(v_actor, p_producer2_id) THEN
    RAISE EXCEPTION 'BATTLE_PAIR_ALREADY_ACTIVE' USING ERRCODE = 'P0002';
  END IF;

  v_cooldown_end := public.get_battle_pair_cooldown_end(
    v_actor,
    p_producer2_id
  );

  IF v_cooldown_end IS NOT NULL THEN
    RAISE EXCEPTION 'BATTLE_PAIR_COOLDOWN'
      USING ERRCODE = 'P0003',
            DETAIL = jsonb_build_object(
              'cooldown_end_at', to_char(v_cooldown_end AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
              'cooldown_days',   v_cooldown_days,
              'opponent_id',     p_producer2_id
            )::text;
  END IF;

  INSERT INTO public.battles (
    title,
    slug,
    description,
    producer1_id,
    producer2_id,
    product1_id,
    product2_id,
    genre_id,
    status,
    winner_id,
    votes_producer1,
    votes_producer2
  )
  VALUES (
    v_title,
    v_slug,
    v_description,
    v_actor,
    p_producer2_id,
    p_product1_id,
    p_product2_id,
    p_genre_id,
    'pending_acceptance',
    NULL,
    0,
    0
  )
  RETURNING id INTO v_new_battle_id;

  RETURN v_new_battle_id;
END;
$$;

-- 3) Acceptation avec beat -------------------------------------------------------
DROP FUNCTION IF EXISTS public.respond_to_battle(uuid, boolean, text);

CREATE FUNCTION public.respond_to_battle(
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

    PERFORM public.recalculate_engagement(v_actor);
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) TO authenticated;

COMMIT;
