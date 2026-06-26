# Battle auto-expiry dedicated notification + J-1 response reminder

**Date:** 2026-06-26
**Author:** Ludovic (via Claude Code)
**Status:** Approved design — implementation pending

## Context

Battles created as `pending_acceptance` auto-cancel at `response_deadline`
(= `created_at + 7 days`) via the cron `expire-pending-battle-invitations`
(every 15 min → `private.expire_pending_battle_invitations`). On cancellation,
the invited producer (`producer2`) loses 8 ELO points.

Two UX gaps in the current system:

1. **Misleading expiry message.** Auto-expiry reuses the generic
   `battle_admin_rejected` template, so both producers receive
   *"La battle a été refusée ou annulée par l'admin"* — wrong: no admin was
   involved, it expired for lack of response. Discriminator already exists:
   the expiry sweep sets `rejection_reason = 'auto_expired_no_response'`.
2. **No reminder before the deadline.** The only notification fires *at*
   cancellation. Nothing warns the invited producer beforehand.

## Goals

- (a) Send a **dedicated, role-differentiated** notification on auto-expiry
  (in-app + email), without an "admin" mention.
- (b) Send a **single J-1 reminder** (~24 h before deadline) to the invited
  producer only.

Non-goals: multi-stage reminders (J-3 + J-1), i18n (system is hardcoded
French), reminding the requester, changing the 7-day window or the ELO penalty.

## Decisions (confirmed by user 2026-06-26)

- Auto-expiry message: **differentiated per role** (requester vs invited).
- Reminder recipient: **invited producer (`producer2`) only**.
- Reminder count: **one, at J-1**.

## Feature (a) — Dedicated auto-expiry notification

Modify `private.notify_battle_users_on_status_change()` (trigger
`on_battle_status_notify_users`, fires `AFTER UPDATE OF status` when new status
∈ {awaiting_admin, rejected, active, cancelled}).

Add a branch on the `cancelled` path:

- **If** `NEW.status = 'cancelled' AND NEW.rejection_reason = 'auto_expired_no_response'`
  → dedicated auto-expiry handling (below).
- **Else** (admin cancellation) → unchanged `battle_admin_rejected` behaviour.

Auto-expiry handling inserts **two distinct rows** (one per producer) for both
the in-app `notifications` table and the `email_queue`, with role-specific text:

| Recipient | in-app title | message |
|---|---|---|
| requester (`producer1`) | « Battle annulée » | `Ta battle "<titre>" a été annulée : <invité> n'a pas répondu dans le délai de 7 jours.` |
| invited (`producer2`) | « Battle expirée » | `La battle "<titre>" a été annulée faute de réponse dans les 7 jours (−8 points de classement).` |

Email: new template `battle_auto_expired`. Payload carries
`recipient_role` (`'requester'` | `'invited'`), `battle_title`, `battle_slug`,
`other_producer_name`, `elo_penalty` (8 for invited, absent/0 for requester),
plus the usual `battle_id`, `recipient_id`, `recipient_name`. Rendering branches
on `recipient_role`.

Edge cases:
- `producer2_id` is always set for user battles; guard the invited insert on
  `producer2_id IS NOT NULL` anyway.
- Reuse the existing per-block `BEGIN…EXCEPTION WHEN others` guards so a notify
  failure never blocks the status update.

## Feature (b) — J-1 response reminder

1. **Schema:** `ALTER TABLE public.battles ADD COLUMN IF NOT EXISTS
   response_reminder_sent_at timestamptz` (nullable). Idempotency flag.
2. **Function:** `private.send_battle_response_reminders(p_limit int DEFAULT 500)`
   `RETURNS integer`, `SECURITY DEFINER`, `search_path = public, pg_temp`.
   Selects battles where:
   - `status = 'pending_acceptance'`
   - `response_deadline IS NOT NULL`
   - `response_deadline > now()` (not already expired)
   - `response_deadline <= now() + interval '24 hours'` (inside J-1 window)
   - `response_reminder_sent_at IS NULL`
   For each: insert in-app notification + `email_queue` row to **producer2 only**
   (template `battle_response_reminder`), then set
   `response_reminder_sent_at = now()`. Returns count reminded. Bounded by
   `p_limit` (clamp 1..1000, like the expiry function).
3. **Email template:** `battle_response_reminder`. Payload: `battle_title`,
   `battle_slug`, `requester_name` (producer1), `response_deadline`,
   `recipient_id`, `recipient_name`. CTA → `/producer/battles`.
4. **Cron:** `send-battle-response-reminders`, hourly (`0 * * * *`), pg_cron
   direct-SQL pattern (unschedule-then-schedule, guarded on `cron` namespace),
   body `SELECT private.send_battle_response_reminders(500);`.

Hourly cadence → reminder fires within ~1 h of the 24-h-before mark. Good enough,
low overhead, and naturally covers battles already in flight when deployed.

## Files touched

- **Migration** `<ts>_battle_auto_expiry_dedicated_notification.sql` — feature (a):
  `CREATE OR REPLACE FUNCTION private.notify_battle_users_on_status_change()`.
- **Migration** `<ts>_battle_response_reminder.sql` — feature (b): column +
  function + cron. All idempotent.
- `supabase/functions/_shared/emailTemplates.ts` — add `battle_auto_expired`
  and `battle_response_reminder` to the `EmailTemplate` union and the
  `REPEATABLE_EMAIL_TEMPLATES` set.
- `supabase/functions/process-email-queue/index.ts` — add two render blocks
  (model on the existing `battle_admin_rejected` / `battle_request_rejected`
  blocks, using `buildBrandedEmailContent`).
- `database.types.ts` — hand-patch `response_reminder_sent_at` on the
  `battles` Row/Insert/Update types.

## Testing (staging)

The Supabase CLI is currently linked to **production** — do NOT `db push` for
testing. Apply DDL + run tests on staging (`haebgsnncuikvfgivxwk`) via MCP,
isolated from prod and from the migration history.

- (a): take/craft a `pending_acceptance` battle on staging, force
  `response_deadline` into the past, run `private.expire_pending_battle_invitations(500)`,
  assert: status `cancelled`; two `notifications` rows with the differentiated
  text; two `email_queue` rows `template = battle_auto_expired` with correct
  `recipient_role`.
- (b): craft a `pending_acceptance` battle with `response_deadline = now() + 12h`,
  run `private.send_battle_response_reminders(500)`, assert: one in-app + one
  `email_queue` row to producer2, `template = battle_response_reminder`,
  `response_reminder_sent_at` set; re-run → **0 new rows** (idempotent).
- TS email rendering verified by code review against existing template blocks.
- Clean up test rows afterwards.

## Deployment

Staging first (validated above). For prod, hand the user exact commands; do not
run `supabase db push` unprompted (CLI is linked to prod). Per project memory,
deploy migrations with `supabase db push` (NOT MCP `apply_migration`, which
causes a `schema_migrations.version` mismatch). Also redeploy the
`process-email-queue` edge function so the new templates render.
