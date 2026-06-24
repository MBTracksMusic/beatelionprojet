/*
  # Battle invitation auto-expiry

  Problem:
  - A user battle invitation is created with status pending_acceptance and locks
    its beat(s) via battle_product_locks. If the invited producer never responds,
    the beat stays locked forever: nothing ever moves a pending_acceptance battle
    out of that state. response_deadline existed (and was indexed) but was never
    populated (rpc_create_battle never set it) and nothing ever swept on it.
  - Net effect in prod: a single ignored invitation holds a beat hostage, and any
    later battle using that beat fails with BATTLE_PRODUCT_ALREADY_OCCUPIED.

  Fix (3 parts):
  1. BEFORE INSERT trigger: every new pending_acceptance battle gets a default
     response_deadline of now() + 7 days (only when not explicitly provided).
     Universal — covers rpc_create_battle and any future creation path.
  2. Backfill: existing pending_acceptance battles with a NULL deadline get
     created_at + 7 days. Invitations created < 7 days ago keep their grace
     period; older ones become eligible for the very next sweep.
  3. private.expire_pending_battle_invitations(): a sweep that cancels
     pending_acceptance battles whose deadline has passed. Setting status to
     'cancelled' fires sync_battle_product_locks (frees the beat) and
     notify_battle_users_on_status_change (notifies both producers). Scheduled
     every 15 minutes via pg_cron.

  Chosen policy (product decision): 7-day deadline, expired -> 'cancelled'.

  Note: the existing status-change notification labels a cancelled battle as
  "annulee par l admin". For an auto-expiry that copy is slightly off; a
  dedicated notification type can be added later without touching this mechanism.
*/

BEGIN;

-- ── 1. Default response_deadline on new pending_acceptance battles ───────────
CREATE OR REPLACE FUNCTION private.set_battle_response_deadline()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.status = 'pending_acceptance' AND NEW.response_deadline IS NULL THEN
    NEW.response_deadline := now() + interval '7 days';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_set_battle_response_deadline ON public.battles;
CREATE TRIGGER trg_set_battle_response_deadline
  BEFORE INSERT ON public.battles
  FOR EACH ROW
  EXECUTE FUNCTION private.set_battle_response_deadline();

-- ── 2. Backfill existing pending invitations missing a deadline ──────────────
-- Only touches response_deadline, so no status/product triggers fire.
UPDATE public.battles
SET response_deadline = created_at + interval '7 days'
WHERE status = 'pending_acceptance'
  AND response_deadline IS NULL;

-- ── 3. Sweep: cancel pending invitations past their deadline ─────────────────
-- Lives in `private` (never REST-exposed) and is granted only to service_role,
-- so no in-body role guard is needed. pg_cron runs it as the job owner.
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

REVOKE ALL ON FUNCTION private.expire_pending_battle_invitations(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.expire_pending_battle_invitations(integer) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION private.expire_pending_battle_invitations(integer) TO service_role;

COMMIT;

-- ── 4. Schedule the sweep every 15 minutes (idempotent) ──────────────────────
-- Direct SQL via pg_cron: no edge function / vault dependency. Skips cleanly if
-- pg_cron is not installed (e.g. a bare local/test database).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    BEGIN
      PERFORM cron.unschedule('expire-pending-battle-invitations');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'expire-pending-battle-invitations',
      '*/15 * * * *',
      $cron$ SELECT private.expire_pending_battle_invitations(500); $cron$
    );
  ELSE
    RAISE NOTICE 'pg_cron not installed; expire-pending-battle-invitations was not scheduled. Invoke private.expire_pending_battle_invitations() from another scheduler.';
  END IF;
END;
$$;
