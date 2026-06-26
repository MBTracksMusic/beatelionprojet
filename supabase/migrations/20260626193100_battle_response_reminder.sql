-- Feature (b): J-1 response reminder for pending battle invitations.
--
-- Battles in 'pending_acceptance' auto-cancel at response_deadline
-- (= created_at + 7 days). Previously the invited producer was only notified at
-- cancellation, never before. This adds a single reminder ~24h before the
-- deadline, sent to the invited producer (producer2) only.
--
-- Idempotency: battles.response_reminder_sent_at guarantees each battle is
-- reminded at most once. The sweep runs hourly (cron below), so the reminder
-- fires within ~1h of the battle entering the final 24h window.

-- 1) Idempotency flag --------------------------------------------------------
ALTER TABLE public.battles
  ADD COLUMN IF NOT EXISTS response_reminder_sent_at timestamptz;

-- 2) Reminder sweep ----------------------------------------------------------
CREATE OR REPLACE FUNCTION private.send_battle_response_reminders(p_limit integer DEFAULT 500)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_limit integer := GREATEST(1, LEAST(COALESCE(p_limit, 500), 1000));
  v_ids   uuid[];
  v_count integer := 0;
BEGIN
  SELECT array_agg(id)
  INTO v_ids
  FROM (
    SELECT id
    FROM public.battles
    WHERE status = 'pending_acceptance'
      AND producer2_id IS NOT NULL
      AND response_deadline IS NOT NULL
      AND response_deadline > now()
      AND response_deadline <= now() + interval '24 hours'
      AND response_reminder_sent_at IS NULL
    ORDER BY response_deadline ASC
    LIMIT v_limit
  ) s;

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  -- In-app notification to the invited producer (producer2) only.
  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message)
    SELECT
      b.producer2_id,
      'battle_response_reminder',
      'Reponse attendue : moins de 24h',
      format(
        'Il te reste moins de 24h pour repondre a la battle "%s". Sans reponse, elle sera annulee automatiquement (-8 points de classement).',
        COALESCE(NULLIF(trim(b.title), ''), 'Battle')
      )
    FROM public.battles b
    WHERE b.id = ANY (v_ids)
      AND b.producer2_id IS NOT NULL;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'battle response reminder in-app notification failed: %', SQLERRM;
  END;

  -- Email to the invited producer (producer2) only.
  BEGIN
    INSERT INTO public.email_queue (user_id, email, template, payload, status)
    SELECT
      NULL::uuid,
      lower(trim(up.email)),
      'battle_response_reminder',
      jsonb_build_object(
        'battle_id', b.id,
        'battle_title', COALESCE(NULLIF(trim(b.title), ''), 'Battle'),
        'battle_slug', COALESCE(b.slug, ''),
        'response_deadline', b.response_deadline,
        'requester_name', COALESCE(NULLIF(trim(up1.full_name), ''), up1.username, 'Le demandeur'),
        'recipient_id', up.id,
        'recipient_name', COALESCE(NULLIF(trim(up.full_name), ''), up.username, ''),
        'source', 'battle_response_reminder_cron'
      ),
      'pending'
    FROM public.battles b
    JOIN public.user_profiles up ON up.id = b.producer2_id
    LEFT JOIN public.user_profiles up1 ON up1.id = b.producer1_id
    WHERE b.id = ANY (v_ids)
      AND up.email IS NOT NULL
      AND length(trim(up.email)) > 0;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'battle response reminder email notification failed: %', SQLERRM;
  END;

  -- Mark reminded (idempotency). Only status is untouched, so no status-change
  -- trigger fires here.
  UPDATE public.battles
  SET response_reminder_sent_at = now()
  WHERE id = ANY (v_ids)
    AND response_reminder_sent_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- 3) Hourly cron -------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    BEGIN
      PERFORM cron.unschedule('send-battle-response-reminders');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    PERFORM cron.schedule(
      'send-battle-response-reminders',
      '0 * * * *',
      $cron$ SELECT private.send_battle_response_reminders(500); $cron$
    );
  ELSE
    RAISE NOTICE 'pg_cron not installed; skipping send-battle-response-reminders schedule';
  END IF;
END;
$$;
