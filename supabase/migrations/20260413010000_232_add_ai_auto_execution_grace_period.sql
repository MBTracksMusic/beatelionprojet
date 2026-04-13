/*
  # AI auto-execution: add 1-hour grace period

  Prevents auto-execution of AI actions created less than 1 hour ago.
  This gives admins a window to manually review and override before
  any automated action is taken.

  Only the WHERE clause of the processing loop is affected.
  All other logic (settings, thresholds, limits) is unchanged.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.agent_auto_execute_ai_battle_actions(
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor        uuid   := auth.uid();
  v_jwt_role     text   := current_setting('request.jwt.claim.role', true);
  v_settings     jsonb;
  v_enabled      boolean;
  v_threshold    numeric;
  v_auto_validate boolean;
  v_auto_cancel   boolean;
  v_limit         integer := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_row           record;
  v_rpc_error     text;
  v_executed      integer := 0;
  v_failed        integer := 0;
  v_skipped       integer := 0;
BEGIN
  -- Auth: service_role or admin
  IF NOT (
    v_jwt_role = 'service_role'
    OR public.is_admin(v_actor)
  ) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  -- Read settings
  SELECT value INTO v_settings
  FROM public.app_settings
  WHERE key = 'ai_auto_execution';

  IF v_settings IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'settings_not_found',
      'executed', 0, 'failed', 0, 'skipped', 0
    );
  END IF;

  v_enabled       := COALESCE((v_settings ->> 'enabled')::boolean,            false);
  v_threshold     := COALESCE((v_settings ->> 'confidence_threshold')::numeric, 0.85);
  v_auto_validate := COALESCE((v_settings ->> 'auto_validate')::boolean,       true);
  v_auto_cancel   := COALESCE((v_settings ->> 'auto_cancel')::boolean,         false);

  IF NOT v_enabled THEN
    RETURN jsonb_build_object(
      'ok', true,
      'reason', 'auto_execution_disabled',
      'executed', 0, 'failed', 0, 'skipped', 0
    );
  END IF;

  -- Process proposed actions — grace period: only act on actions older than 1 hour
  FOR v_row IN
    SELECT a.id, a.action_type, a.entity_id, a.confidence_score, a.ai_decision
    FROM public.ai_admin_actions a
    WHERE a.status      = 'proposed'
      AND a.entity_type = 'battle'
      AND a.action_type IN ('battle_validate', 'battle_cancel')
      AND a.confidence_score IS NOT NULL
      AND a.confidence_score >= v_threshold
      AND a.created_at < now() - interval '1 hour'
    ORDER BY a.confidence_score DESC, a.created_at ASC
    LIMIT v_limit
  LOOP
    -- Per-type toggle check
    IF v_row.action_type = 'battle_validate' AND NOT v_auto_validate THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF v_row.action_type = 'battle_cancel' AND NOT v_auto_cancel THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Execute
    v_rpc_error := NULL;
    BEGIN
      IF v_row.action_type = 'battle_validate' THEN
        PERFORM public.admin_validate_battle(v_row.entity_id);
      ELSIF v_row.action_type = 'battle_cancel' THEN
        PERFORM public.admin_cancel_battle(v_row.entity_id);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_rpc_error := SQLERRM;
    END;

    IF v_rpc_error IS NOT NULL THEN
      UPDATE public.ai_admin_actions
      SET status      = 'failed',
          error       = v_rpc_error,
          executed_at = now(),
          executed_by = NULL
      WHERE id = v_row.id;

      INSERT INTO public.ai_training_feedback (
        action_id, ai_prediction, human_decision, delta, created_by
      ) VALUES (
        v_row.id,
        v_row.ai_decision,
        jsonb_build_object(
          'decision',    'auto_execute_failed',
          'action_type', v_row.action_type,
          'entity_id',   v_row.entity_id,
          'error',       v_rpc_error
        ),
        1,
        NULL
      );

      v_failed := v_failed + 1;
    ELSE
      UPDATE public.ai_admin_actions
      SET status        = 'executed',
          human_override = false,
          error         = NULL,
          executed_at   = now(),
          executed_by   = NULL
      WHERE id = v_row.id;

      INSERT INTO public.ai_training_feedback (
        action_id, ai_prediction, human_decision, delta, created_by
      ) VALUES (
        v_row.id,
        v_row.ai_decision,
        jsonb_build_object(
          'decision',    'auto_execute',
          'action_type', v_row.action_type,
          'entity_id',   v_row.entity_id
        ),
        0,
        NULL
      );

      v_executed := v_executed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',            true,
    'executed',      v_executed,
    'failed',        v_failed,
    'skipped',       v_skipped,
    'threshold',     v_threshold,
    'auto_validate', v_auto_validate,
    'auto_cancel',   v_auto_cancel
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.agent_auto_execute_ai_battle_actions(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.agent_auto_execute_ai_battle_actions(integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.agent_auto_execute_ai_battle_actions(integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.agent_auto_execute_ai_battle_actions(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agent_auto_execute_ai_battle_actions(integer) TO service_role;

COMMIT;
