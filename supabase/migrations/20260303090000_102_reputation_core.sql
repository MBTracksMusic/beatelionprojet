/*
  # Reputation core + leaderboard + admin overrides

  Adds:
  - user_reputation
  - reputation_events
  - reputation_rules
  - internal/apply RPCs
  - leaderboard RPC
  - admin overview / admin adjust RPCs
  - automatic reputation row bootstrap
*/

BEGIN;

CREATE TABLE IF NOT EXISTS public.user_reputation (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  xp bigint NOT NULL DEFAULT 0,
  level integer NOT NULL DEFAULT 1 CHECK (level >= 1),
  rank_tier text NOT NULL DEFAULT 'bronze' CHECK (rank_tier IN ('bronze', 'silver', 'gold', 'platinum', 'diamond')),
  forum_xp bigint NOT NULL DEFAULT 0,
  battle_xp bigint NOT NULL DEFAULT 0,
  commerce_xp bigint NOT NULL DEFAULT 0,
  reputation_score numeric NOT NULL DEFAULT 0,
  last_event_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reputation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  source text NOT NULL,
  event_type text NOT NULL,
  entity_type text NULL,
  entity_id uuid NULL,
  delta_xp integer NOT NULL,
  metadata jsonb NULL DEFAULT '{}'::jsonb,
  idempotency_key text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reputation_rules (
  key text PRIMARY KEY,
  source text NOT NULL,
  event_type text NOT NULL,
  delta_xp integer NOT NULL,
  cooldown_sec integer NOT NULL DEFAULT 0,
  max_per_day integer NULL,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reputation_events_user_created_desc
  ON public.reputation_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reputation_events_source_event_created_desc
  ON public.reputation_events (source, event_type, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_reputation_events_idempotency_key
  ON public.reputation_events (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_reputation_rank_xp
  ON public.user_reputation (rank_tier, xp DESC);

CREATE OR REPLACE FUNCTION public.reputation_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_reputation_touch_updated_at ON public.user_reputation;
CREATE TRIGGER trg_user_reputation_touch_updated_at
  BEFORE UPDATE ON public.user_reputation
  FOR EACH ROW
  EXECUTE FUNCTION public.reputation_touch_updated_at();

DROP TRIGGER IF EXISTS trg_reputation_rules_touch_updated_at ON public.reputation_rules;
CREATE TRIGGER trg_reputation_rules_touch_updated_at
  BEFORE UPDATE ON public.reputation_rules
  FOR EACH ROW
  EXECUTE FUNCTION public.reputation_touch_updated_at();

CREATE OR REPLACE FUNCTION public.reputation_rank_tier_value(p_rank_tier text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE lower(COALESCE(p_rank_tier, 'bronze'))
    WHEN 'diamond' THEN 5
    WHEN 'platinum' THEN 4
    WHEN 'gold' THEN 3
    WHEN 'silver' THEN 2
    ELSE 1
  END;
$$;

CREATE OR REPLACE FUNCTION public.reputation_calculate_level(p_xp bigint)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT GREATEST(1, floor(sqrt(GREATEST(COALESCE(p_xp, 0), 0)::numeric / 25.0))::integer + 1);
$$;

CREATE OR REPLACE FUNCTION public.reputation_calculate_rank_tier(p_xp bigint)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN COALESCE(p_xp, 0) >= 2000 THEN 'diamond'
    WHEN COALESCE(p_xp, 0) >= 1000 THEN 'platinum'
    WHEN COALESCE(p_xp, 0) >= 400 THEN 'gold'
    WHEN COALESCE(p_xp, 0) >= 120 THEN 'silver'
    ELSE 'bronze'
  END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_user_reputation_row(p_user_id uuid)
RETURNS public.user_reputation
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.user_reputation%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  INSERT INTO public.user_reputation (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT *
  INTO v_row
  FROM public.user_reputation
  WHERE user_id = p_user_id;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_user_reputation_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.ensure_user_reputation_row(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_user_reputation_row ON public.user_profiles;
CREATE TRIGGER trg_sync_user_reputation_row
  AFTER INSERT ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_user_reputation_row();

CREATE OR REPLACE FUNCTION public.apply_reputation_event_internal(
  p_user_id uuid,
  p_source text,
  p_event_type text,
  p_entity_type text DEFAULT NULL,
  p_entity_id uuid DEFAULT NULL,
  p_delta integer DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text DEFAULT NULL
)
RETURNS TABLE (
  applied boolean,
  event_id uuid,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  skipped_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rule public.reputation_rules%ROWTYPE;
  v_has_rule boolean := false;
  v_now timestamptz := now();
  v_effective_delta integer;
  v_effective_source text := lower(COALESCE(NULLIF(btrim(p_source), ''), 'system'));
  v_effective_event_type text := lower(COALESCE(NULLIF(btrim(p_event_type), ''), 'unknown'));
  v_metadata jsonb := COALESCE(p_metadata, '{}'::jsonb);
  v_multiplier numeric := 1;
  v_existing_event public.reputation_events%ROWTYPE;
  v_recent_count integer := 0;
  v_last_event_at timestamptz;
  v_target public.user_reputation%ROWTYPE;
  v_new_xp bigint;
  v_new_level integer;
  v_new_rank_tier text;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  PERFORM public.ensure_user_reputation_row(p_user_id);

  IF p_idempotency_key IS NOT NULL AND btrim(p_idempotency_key) <> '' THEN
    SELECT *
    INTO v_existing_event
    FROM public.reputation_events
    WHERE idempotency_key = btrim(p_idempotency_key)
    LIMIT 1;

    IF FOUND THEN
      SELECT *
      INTO v_target
      FROM public.user_reputation
      WHERE user_id = p_user_id;

      RETURN QUERY
      SELECT
        false,
        v_existing_event.id,
        v_target.xp,
        v_target.level,
        v_target.rank_tier,
        v_target.forum_xp,
        v_target.battle_xp,
        v_target.commerce_xp,
        v_target.reputation_score,
        'duplicate_idempotency_key'::text;
      RETURN;
    END IF;
  END IF;

  SELECT *
  INTO v_rule
  FROM public.reputation_rules
  WHERE source = v_effective_source
    AND event_type = v_effective_event_type
  LIMIT 1;

  v_has_rule := FOUND;

  IF v_has_rule AND v_rule.is_enabled = false THEN
    SELECT *
    INTO v_target
    FROM public.user_reputation
    WHERE user_id = p_user_id;

    RETURN QUERY
    SELECT
      false,
      NULL::uuid,
      v_target.xp,
      v_target.level,
      v_target.rank_tier,
      v_target.forum_xp,
      v_target.battle_xp,
      v_target.commerce_xp,
      v_target.reputation_score,
      'rule_disabled'::text;
    RETURN;
  END IF;

  v_effective_delta := COALESCE(
    p_delta,
    CASE WHEN v_has_rule THEN v_rule.delta_xp ELSE NULL END
  );

  IF v_effective_delta IS NULL THEN
    RAISE EXCEPTION 'reputation_rule_not_found';
  END IF;

  IF jsonb_typeof(v_metadata) = 'object' AND (v_metadata ? 'xp_multiplier') THEN
    v_multiplier := GREATEST(
      0,
      COALESCE(NULLIF(v_metadata->>'xp_multiplier', '')::numeric, 1)
    );
  END IF;

  v_effective_delta := CASE
    WHEN v_multiplier IS NULL OR v_multiplier = 1 THEN v_effective_delta
    WHEN v_effective_delta >= 0 THEN floor(v_effective_delta::numeric * v_multiplier)::integer
    ELSE ceil(v_effective_delta::numeric * v_multiplier)::integer
  END;

  IF v_has_rule AND v_rule.cooldown_sec > 0 THEN
    SELECT max(created_at)
    INTO v_last_event_at
    FROM public.reputation_events
    WHERE user_id = p_user_id
      AND source = v_effective_source
      AND event_type = v_effective_event_type;

    IF v_last_event_at IS NOT NULL AND v_last_event_at >= v_now - make_interval(secs => v_rule.cooldown_sec) THEN
      SELECT *
      INTO v_target
      FROM public.user_reputation
      WHERE user_id = p_user_id;

      RETURN QUERY
      SELECT
        false,
        NULL::uuid,
        v_target.xp,
        v_target.level,
        v_target.rank_tier,
        v_target.forum_xp,
        v_target.battle_xp,
        v_target.commerce_xp,
        v_target.reputation_score,
        'cooldown_active'::text;
      RETURN;
    END IF;
  END IF;

  IF v_has_rule AND v_rule.max_per_day IS NOT NULL THEN
    SELECT count(*)::integer
    INTO v_recent_count
    FROM public.reputation_events
    WHERE user_id = p_user_id
      AND source = v_effective_source
      AND event_type = v_effective_event_type
      AND created_at >= date_trunc('day', v_now);

    IF v_recent_count >= v_rule.max_per_day THEN
      SELECT *
      INTO v_target
      FROM public.user_reputation
      WHERE user_id = p_user_id;

      RETURN QUERY
      SELECT
        false,
        NULL::uuid,
        v_target.xp,
        v_target.level,
        v_target.rank_tier,
        v_target.forum_xp,
        v_target.battle_xp,
        v_target.commerce_xp,
        v_target.reputation_score,
        'daily_cap_reached'::text;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.reputation_events (
    user_id,
    source,
    event_type,
    entity_type,
    entity_id,
    delta_xp,
    metadata,
    idempotency_key,
    created_at
  )
  VALUES (
    p_user_id,
    v_effective_source,
    v_effective_event_type,
    NULLIF(btrim(COALESCE(p_entity_type, '')), ''),
    p_entity_id,
    v_effective_delta,
    v_metadata,
    NULLIF(btrim(COALESCE(p_idempotency_key, '')), ''),
    v_now
  )
  RETURNING * INTO v_existing_event;

  SELECT *
  INTO v_target
  FROM public.user_reputation
  WHERE user_id = p_user_id
  FOR UPDATE;

  v_new_xp := GREATEST(0, COALESCE(v_target.xp, 0) + v_effective_delta);
  v_new_level := public.reputation_calculate_level(v_new_xp);
  v_new_rank_tier := public.reputation_calculate_rank_tier(v_new_xp);

  UPDATE public.user_reputation
  SET xp = v_new_xp,
      level = v_new_level,
      rank_tier = v_new_rank_tier,
      forum_xp = GREATEST(
        0,
        COALESCE(v_target.forum_xp, 0)
        + CASE WHEN v_effective_source = 'forum' THEN v_effective_delta ELSE 0 END
      ),
      battle_xp = GREATEST(
        0,
        COALESCE(v_target.battle_xp, 0)
        + CASE WHEN v_effective_source = 'battles' THEN v_effective_delta ELSE 0 END
      ),
      commerce_xp = GREATEST(
        0,
        COALESCE(v_target.commerce_xp, 0)
        + CASE WHEN v_effective_source = 'commerce' THEN v_effective_delta ELSE 0 END
      ),
      reputation_score = v_new_xp,
      last_event_at = v_now,
      updated_at = v_now
  WHERE user_id = p_user_id;

  SELECT *
  INTO v_target
  FROM public.user_reputation
  WHERE user_id = p_user_id;

  RETURN QUERY
  SELECT
    true,
    v_existing_event.id,
    v_target.xp,
    v_target.level,
    v_target.rank_tier,
    v_target.forum_xp,
    v_target.battle_xp,
    v_target.commerce_xp,
    v_target.reputation_score,
    NULL::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_apply_reputation_event(
  p_user_id uuid,
  p_source text,
  p_event_type text,
  p_entity_type text DEFAULT NULL,
  p_entity_id uuid DEFAULT NULL,
  p_delta integer DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text DEFAULT NULL
)
RETURNS TABLE (
  applied boolean,
  event_id uuid,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  skipped_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'service_role_or_admin_required';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.apply_reputation_event_internal(
    p_user_id => p_user_id,
    p_source => p_source,
    p_event_type => p_event_type,
    p_entity_type => p_entity_type,
    p_entity_id => p_entity_id,
    p_delta => p_delta,
    p_metadata => p_metadata,
    p_idempotency_key => p_idempotency_key
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_adjust_reputation(
  p_user_id uuid,
  p_delta_xp integer,
  p_reason text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  applied boolean,
  event_id uuid,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  skipped_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_reason text := COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'admin_adjustment');
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_required';
  END IF;

  IF p_delta_xp = 0 THEN
    RAISE EXCEPTION 'delta_required';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.apply_reputation_event_internal(
    p_user_id => p_user_id,
    p_source => 'admin',
    p_event_type => 'admin_adjustment',
    p_entity_type => 'user',
    p_entity_id => p_user_id,
    p_delta => p_delta_xp,
    p_metadata => jsonb_build_object(
      'admin_user_id', v_actor,
      'reason', v_reason
    ) || COALESCE(p_metadata, '{}'::jsonb),
    p_idempotency_key => NULL
  );

  PERFORM public.log_admin_action_audit(
    p_admin_user_id => v_actor,
    p_action_type => 'admin_adjust_reputation',
    p_entity_type => 'user',
    p_entity_id => p_user_id,
    p_source => 'rpc',
    p_context => jsonb_build_object(
      'reason', v_reason,
      'delta_xp', p_delta_xp
    ),
    p_extra_details => COALESCE(p_metadata, '{}'::jsonb),
    p_success => true,
    p_error => NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_get_leaderboard(
  p_period text DEFAULT 'week',
  p_source text DEFAULT 'overall',
  p_limit integer DEFAULT 10
)
RETURNS TABLE (
  user_id uuid,
  username text,
  avatar_url text,
  producer_tier public.producer_tier_type,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  period_xp bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH params AS (
    SELECT
      CASE lower(COALESCE(p_period, 'week'))
        WHEN 'month' THEN now() - interval '30 days'
        ELSE now() - interval '7 days'
      END AS period_start,
      CASE lower(COALESCE(p_source, 'overall'))
        WHEN 'forum' THEN 'forum'
        WHEN 'battle' THEN 'battles'
        WHEN 'battles' THEN 'battles'
        WHEN 'commerce' THEN 'commerce'
        ELSE 'overall'
      END AS source_filter,
      GREATEST(1, LEAST(COALESCE(p_limit, 10), 100)) AS row_limit
  ),
  event_scores AS (
    SELECT
      re.user_id,
      COALESCE(sum(re.delta_xp), 0)::bigint AS period_xp
    FROM public.reputation_events re
    CROSS JOIN params p
    WHERE re.created_at >= p.period_start
      AND (
        p.source_filter = 'overall'
        OR re.source = p.source_filter
      )
    GROUP BY re.user_id
  )
  SELECT
    up.id AS user_id,
    up.username,
    up.avatar_url,
    up.producer_tier,
    ur.xp,
    ur.level,
    ur.rank_tier,
    ur.forum_xp,
    ur.battle_xp,
    ur.commerce_xp,
    ur.reputation_score,
    COALESCE(es.period_xp, 0) AS period_xp
  FROM public.user_reputation ur
  JOIN public.user_profiles up ON up.id = ur.user_id
  LEFT JOIN event_scores es ON es.user_id = ur.user_id
  CROSS JOIN params p
  WHERE up.username IS NOT NULL
  ORDER BY
    COALESCE(es.period_xp, 0) DESC,
    CASE p.source_filter
      WHEN 'forum' THEN ur.forum_xp
      WHEN 'battles' THEN ur.battle_xp
      WHEN 'commerce' THEN ur.commerce_xp
      ELSE ur.xp
    END DESC,
    ur.xp DESC,
    up.created_at ASC
  LIMIT (SELECT row_limit FROM params);
$$;

CREATE OR REPLACE FUNCTION public.rpc_admin_get_reputation_overview(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  user_id uuid,
  username text,
  email text,
  role text,
  avatar_url text,
  producer_tier public.producer_tier_type,
  xp bigint,
  level integer,
  rank_tier text,
  forum_xp bigint,
  battle_xp bigint,
  commerce_xp bigint,
  reputation_score numeric,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_search text := NULLIF(lower(btrim(COALESCE(p_search, ''))), '');
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  RETURN QUERY
  SELECT
    up.id,
    up.username,
    up.email,
    up.role::text,
    up.avatar_url,
    up.producer_tier,
    ur.xp,
    ur.level,
    ur.rank_tier,
    ur.forum_xp,
    ur.battle_xp,
    ur.commerce_xp,
    ur.reputation_score,
    ur.updated_at
  FROM public.user_profiles up
  JOIN public.user_reputation ur ON ur.user_id = up.id
  WHERE (
    v_search IS NULL
    OR lower(COALESCE(up.username, '')) LIKE '%' || v_search || '%'
    OR lower(COALESCE(up.email, '')) LIKE '%' || v_search || '%'
  )
  ORDER BY ur.xp DESC, up.created_at ASC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
END;
$$;

ALTER TABLE public.user_reputation ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_rules ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.user_reputation FROM PUBLIC;
REVOKE ALL ON TABLE public.user_reputation FROM anon;
REVOKE ALL ON TABLE public.user_reputation FROM authenticated;
GRANT SELECT ON TABLE public.user_reputation TO anon;
GRANT SELECT ON TABLE public.user_reputation TO authenticated;
GRANT ALL ON TABLE public.user_reputation TO service_role;

REVOKE ALL ON TABLE public.reputation_events FROM PUBLIC;
REVOKE ALL ON TABLE public.reputation_events FROM anon;
REVOKE ALL ON TABLE public.reputation_events FROM authenticated;
GRANT SELECT ON TABLE public.reputation_events TO authenticated;
GRANT ALL ON TABLE public.reputation_events TO service_role;

REVOKE ALL ON TABLE public.reputation_rules FROM PUBLIC;
REVOKE ALL ON TABLE public.reputation_rules FROM anon;
REVOKE ALL ON TABLE public.reputation_rules FROM authenticated;
GRANT SELECT ON TABLE public.reputation_rules TO anon;
GRANT SELECT ON TABLE public.reputation_rules TO authenticated;
GRANT ALL ON TABLE public.reputation_rules TO service_role;

DROP POLICY IF EXISTS "User reputation readable" ON public.user_reputation;
CREATE POLICY "User reputation readable"
  ON public.user_reputation
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Reputation events readable by owner or admin" ON public.reputation_events;
CREATE POLICY "Reputation events readable by owner or admin"
  ON public.reputation_events
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_admin(auth.uid())
  );

DROP POLICY IF EXISTS "Reputation rules readable" ON public.reputation_rules;
CREATE POLICY "Reputation rules readable"
  ON public.reputation_rules
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Admins can manage reputation rules" ON public.reputation_rules;
CREATE POLICY "Admins can manage reputation rules"
  ON public.reputation_rules
  FOR ALL
  TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

INSERT INTO public.user_reputation (user_id)
SELECT up.id
FROM public.user_profiles up
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO public.reputation_rules (key, source, event_type, delta_xp, cooldown_sec, max_per_day, is_enabled)
VALUES
  ('forum_topic_created', 'forum', 'forum_topic_created', 10, 15, 50, true),
  ('forum_post_created', 'forum', 'forum_post_created', 4, 10, 120, true),
  ('forum_post_liked', 'forum', 'forum_post_liked', 2, 0, 200, true),
  ('battle_won', 'battles', 'battle_won', 50, 0, NULL, true),
  ('battle_participation', 'battles', 'battle_participation', 10, 0, NULL, true),
  ('moderation_blocked', 'forum', 'moderation_blocked', -20, 0, NULL, true),
  ('moderation_review', 'forum', 'moderation_review', -5, 0, NULL, true),
  ('admin_adjustment', 'admin', 'admin_adjustment', 0, 0, NULL, true)
ON CONFLICT (key) DO UPDATE
SET source = EXCLUDED.source,
    event_type = EXCLUDED.event_type,
    delta_xp = EXCLUDED.delta_xp,
    cooldown_sec = EXCLUDED.cooldown_sec,
    max_per_day = EXCLUDED.max_per_day,
    is_enabled = EXCLUDED.is_enabled,
    updated_at = now();

REVOKE ALL ON FUNCTION public.ensure_user_reputation_row(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_user_reputation_row(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.ensure_user_reputation_row(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_user_reputation_row(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.apply_reputation_event_internal(uuid, text, text, text, uuid, integer, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_reputation_event_internal(uuid, text, text, text, uuid, integer, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.apply_reputation_event_internal(uuid, text, text, text, uuid, integer, jsonb, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.apply_reputation_event_internal(uuid, text, text, text, uuid, integer, jsonb, text) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_apply_reputation_event(uuid, text, text, text, uuid, integer, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_apply_reputation_event(uuid, text, text, text, uuid, integer, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_apply_reputation_event(uuid, text, text, text, uuid, integer, jsonb, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_apply_reputation_event(uuid, text, text, text, uuid, integer, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.rpc_apply_reputation_event(uuid, text, text, text, uuid, integer, jsonb, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_adjust_reputation(uuid, integer, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_adjust_reputation(uuid, integer, text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.admin_adjust_reputation(uuid, integer, text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust_reputation(uuid, integer, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust_reputation(uuid, integer, text, jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_get_leaderboard(text, text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_leaderboard(text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_leaderboard(text, text, integer) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_admin_get_reputation_overview(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_admin_get_reputation_overview(text, integer) FROM anon;
REVOKE ALL ON FUNCTION public.rpc_admin_get_reputation_overview(text, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_get_reputation_overview(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_get_reputation_overview(text, integer) TO service_role;

COMMIT;
