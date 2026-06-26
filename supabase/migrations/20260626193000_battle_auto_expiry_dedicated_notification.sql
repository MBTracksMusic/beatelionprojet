-- Feature (a): dedicated, role-differentiated notification on battle auto-expiry.
--
-- Until now, auto-expiry (no response within 7 days) reused the generic
-- 'battle_admin_rejected' template, so both producers were told the battle was
-- "refusee ou annulee par l admin" -- misleading, since no admin was involved.
--
-- The expiry sweep (private.expire_pending_battle_invitations) sets
-- rejection_reason = 'auto_expired_no_response' on the cancelled battle. We use
-- that as the discriminator: on that specific path we emit dedicated, per-role
-- notifications (in-app + email) instead of the admin-rejection wording.
-- Admin cancellations (any other rejection_reason) keep the previous behaviour.

CREATE OR REPLACE FUNCTION private.notify_battle_users_on_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_battle_title text := COALESCE(NULLIF(trim(NEW.title), ''), 'Battle');
  v_battle_slug text := COALESCE(NEW.slug, '');
  v_producer1_name text;
  v_producer2_name text;
  v_type text;
  v_title text;
  v_message text;
  v_template text;
  v_payload jsonb;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status::text NOT IN ('awaiting_admin', 'rejected', 'active', 'cancelled') THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(trim(up.full_name), ''), up.username, 'Le demandeur')
  INTO v_producer1_name
  FROM public.user_profiles up
  WHERE up.id = NEW.producer1_id;

  SELECT COALESCE(NULLIF(trim(up.full_name), ''), up.username, 'Le producteur invite')
  INTO v_producer2_name
  FROM public.user_profiles up
  WHERE up.id = NEW.producer2_id;

  v_producer1_name := COALESCE(v_producer1_name, 'Le demandeur');
  v_producer2_name := COALESCE(v_producer2_name, 'Le producteur invite');

  -- ===========================================================================
  -- Dedicated auto-expiry path (no response within 7 days). Handled first, with
  -- per-recipient text, then we return early so the generic logic is skipped.
  -- ===========================================================================
  IF NEW.status::text = 'cancelled'
     AND COALESCE(NEW.rejection_reason, '') = 'auto_expired_no_response' THEN

    v_payload := jsonb_build_object(
      'battle_id', NEW.id,
      'battle_title', v_battle_title,
      'battle_slug', v_battle_slug,
      'status_before', OLD.status::text,
      'status_after', NEW.status::text,
      'producer1_id', NEW.producer1_id,
      'producer1_name', v_producer1_name,
      'producer2_id', NEW.producer2_id,
      'producer2_name', v_producer2_name,
      'rejection_reason', NEW.rejection_reason,
      'source', 'battle_auto_expiry_notification_trigger'
    );

    -- In-app notifications: one row per producer, role-specific wording.
    BEGIN
      IF NEW.producer1_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, message)
        VALUES (
          NEW.producer1_id,
          'battle_auto_expired',
          'Battle annulee',
          format(
            'Ta battle "%s" a ete annulee : %s n a pas repondu dans le delai de 7 jours.',
            v_battle_title,
            v_producer2_name
          )
        );
      END IF;

      IF NEW.producer2_id IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, message)
        VALUES (
          NEW.producer2_id,
          'battle_auto_expired',
          'Battle expiree',
          format(
            'La battle "%s" a ete annulee faute de reponse dans les 7 jours (-8 points de classement).',
            v_battle_title
          )
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'battle auto-expiry in-app notification failed for battle %: %', NEW.id, SQLERRM;
    END;

    -- Emails: one row per producer, role-specific payload.
    BEGIN
      -- Requester (producer1)
      INSERT INTO public.email_queue (user_id, email, template, payload, status)
      SELECT
        NULL::uuid,
        lower(trim(up.email)),
        'battle_auto_expired',
        v_payload || jsonb_build_object(
          'recipient_id', up.id,
          'recipient_name', COALESCE(NULLIF(trim(up.full_name), ''), up.username, ''),
          'recipient_role', 'requester',
          'other_producer_name', v_producer2_name,
          'elo_penalty', 0
        ),
        'pending'
      FROM public.user_profiles up
      WHERE up.id = NEW.producer1_id
        AND up.email IS NOT NULL
        AND length(trim(up.email)) > 0;

      -- Invited (producer2)
      INSERT INTO public.email_queue (user_id, email, template, payload, status)
      SELECT
        NULL::uuid,
        lower(trim(up.email)),
        'battle_auto_expired',
        v_payload || jsonb_build_object(
          'recipient_id', up.id,
          'recipient_name', COALESCE(NULLIF(trim(up.full_name), ''), up.username, ''),
          'recipient_role', 'invited',
          'other_producer_name', v_producer1_name,
          'elo_penalty', 8
        ),
        'pending'
      FROM public.user_profiles up
      WHERE up.id = NEW.producer2_id
        AND up.email IS NOT NULL
        AND length(trim(up.email)) > 0;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'battle auto-expiry email notification failed for battle %: %', NEW.id, SQLERRM;
    END;

    RETURN NEW;
  END IF;

  -- ===========================================================================
  -- Generic status-change notifications (unchanged).
  -- ===========================================================================
  IF OLD.status::text = 'pending_acceptance' AND NEW.status::text = 'awaiting_admin' THEN
    v_type := 'battle_invitation_accepted';
    v_title := 'Invitation battle acceptee';
    v_message := format(
      '%s a accepte la battle "%s". Elle attend maintenant la validation admin.',
      v_producer2_name,
      v_battle_title
    );
    v_template := 'battle_request_accepted';
  ELSIF OLD.status::text = 'pending_acceptance' AND NEW.status::text = 'rejected' THEN
    v_type := 'battle_invitation_rejected';
    v_title := 'Invitation battle refusee';
    v_message := format(
      '%s a refuse la battle "%s"%s',
      v_producer2_name,
      v_battle_title,
      CASE
        WHEN NULLIF(trim(COALESCE(NEW.rejection_reason, '')), '') IS NOT NULL
          THEN format(' : %s', NEW.rejection_reason)
        ELSE '.'
      END
    );
    v_template := 'battle_request_rejected';
  ELSIF NEW.status::text = 'active' THEN
    v_type := 'battle_admin_approved';
    v_title := 'Battle validee';
    v_message := format(
      'La battle "%s" a ete validee par l admin et est maintenant ouverte au vote.',
      v_battle_title
    );
    v_template := 'battle_admin_approved';
  ELSIF NEW.status::text = 'cancelled' THEN
    v_type := 'battle_admin_rejected';
    v_title := 'Battle non validee';
    v_message := format(
      'La battle "%s" a ete refusee ou annulee par l admin.',
      v_battle_title
    );
    v_template := 'battle_admin_rejected';
  END IF;

  IF v_type IS NULL OR v_template IS NULL THEN
    RETURN NEW;
  END IF;

  v_payload := jsonb_build_object(
    'battle_id', NEW.id,
    'battle_title', v_battle_title,
    'battle_slug', v_battle_slug,
    'status_before', OLD.status::text,
    'status_after', NEW.status::text,
    'producer1_id', NEW.producer1_id,
    'producer1_name', v_producer1_name,
    'producer2_id', NEW.producer2_id,
    'producer2_name', v_producer2_name,
    'rejection_reason', NEW.rejection_reason,
    'admin_validated_at', NEW.admin_validated_at,
    'voting_ends_at', NEW.voting_ends_at,
    'source', 'battle_status_user_notification_trigger'
  );

  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message)
    SELECT DISTINCT r.user_id, v_type, v_title, v_message
    FROM (
      SELECT NEW.producer1_id AS user_id
      WHERE v_type IN ('battle_invitation_accepted', 'battle_invitation_rejected', 'battle_admin_approved', 'battle_admin_rejected')
      UNION ALL
      SELECT NEW.producer2_id AS user_id
      WHERE v_type IN ('battle_admin_approved', 'battle_admin_rejected')
        AND NEW.producer2_id IS NOT NULL
    ) r
    WHERE r.user_id IS NOT NULL;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'battle user in-app notification failed for battle %: %', NEW.id, SQLERRM;
  END;

  BEGIN
    INSERT INTO public.email_queue (user_id, email, template, payload, status)
    SELECT
      NULL::uuid,
      lower(trim(up.email)),
      v_template,
      v_payload || jsonb_build_object(
        'recipient_id', up.id,
        'recipient_name', COALESCE(NULLIF(trim(up.full_name), ''), up.username, '')
      ),
      'pending'
    FROM (
      SELECT NEW.producer1_id AS user_id
      WHERE v_type IN ('battle_invitation_accepted', 'battle_invitation_rejected', 'battle_admin_approved', 'battle_admin_rejected')
      UNION ALL
      SELECT NEW.producer2_id AS user_id
      WHERE v_type IN ('battle_admin_approved', 'battle_admin_rejected')
        AND NEW.producer2_id IS NOT NULL
    ) r
    JOIN public.user_profiles up ON up.id = r.user_id
    WHERE up.email IS NOT NULL
      AND length(trim(up.email)) > 0;
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'battle user email notification failed for battle %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;
