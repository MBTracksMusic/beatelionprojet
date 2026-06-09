/*
  # Fix database advisor warnings, phase 1

  Safe mechanical fixes only:
  - rewrite selected RLS policies so auth/current_setting calls are evaluated
    once via initplans instead of per row;
  - drop duplicate indexes where another identical index remains.

  Policy predicates are preserved verbatim apart from wrapping:
    auth.uid()          -> (SELECT auth.uid())
    auth.role()         -> (SELECT auth.role())
    auth.email()        -> (SELECT auth.email())
    current_setting(...) -> (SELECT current_setting(...))
*/

BEGIN;

DO $$
DECLARE
  target record;
  pol record;
  v_roles text;
  v_qual text;
  v_check text;
  v_sql text;
BEGIN
  FOR target IN
    SELECT *
    FROM (
      VALUES
        ('products', 'Active producers can create products'),
        ('failed_credit_allocations', 'Service role can insert failed credit allocations'),
        ('battle_quality_snapshots', 'Admins can insert battle quality snapshots via RPC only'),
        ('stripe_payout_failures', 'Service role can insert payout failures'),
        ('battle_quality_snapshots', 'Admins can update battle quality snapshots via RPC only'),
        ('battle_votes', 'Confirmed users can vote'),
        ('battle_comments', 'Confirmed users can comment'),
        ('forum_likes', 'Likes via RPC only'),
        ('forum_post_likes', 'Likes via RPC only'),
        ('products', 'Producers can update own unsold products'),
        ('stripe_payout_failures', 'Service role can select all payout failures'),
        ('failed_credit_allocations', 'Service role can select failed credit allocations'),
        ('failed_credit_allocations', 'Service role can update failed credit allocations'),
        ('waitlist', 'User reads own waitlist entry'),
        ('user_music_preferences', 'Users can insert music preferences via RPC only'),
        ('battle_vote_feedback', 'Users can submit battle vote feedback via RPC only'),
        ('user_music_preferences', 'Users can update music preferences via RPC only'),
        ('battle_share_events', 'Battle share events readable by owner or admin')
    ) AS t(tablename, policyname)
  LOOP
    SELECT *
    INTO pol
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = target.tablename
      AND policyname = target.policyname;

    IF NOT FOUND THEN
      RAISE NOTICE 'Policy %.% not found; skipping', target.tablename, target.policyname;
      CONTINUE;
    END IF;

    SELECT string_agg(
      CASE WHEN r = 'public' THEN 'public' ELSE quote_ident(r) END,
      ', '
      ORDER BY r
    )
    INTO v_roles
    FROM unnest(pol.roles) AS r;

    v_qual := pol.qual;
    v_check := pol.with_check;

    IF v_qual IS NOT NULL THEN
      v_qual := replace(v_qual, '"auth"."uid"()', '(SELECT auth.uid())');
      v_qual := replace(v_qual, 'auth.uid()', '(SELECT auth.uid())');
      v_qual := replace(v_qual, '"auth"."role"()', '(SELECT auth.role())');
      v_qual := replace(v_qual, 'auth.role()', '(SELECT auth.role())');
      v_qual := replace(v_qual, '"auth"."email"()', '(SELECT auth.email())');
      v_qual := replace(v_qual, 'auth.email()', '(SELECT auth.email())');
      v_qual := regexp_replace(v_qual, '"current_setting"\(([^()]*)\)', '(SELECT current_setting(\1))', 'g');
      v_qual := regexp_replace(v_qual, 'current_setting\(([^()]*)\)', '(SELECT current_setting(\1))', 'g');
    END IF;

    IF v_check IS NOT NULL THEN
      v_check := replace(v_check, '"auth"."uid"()', '(SELECT auth.uid())');
      v_check := replace(v_check, 'auth.uid()', '(SELECT auth.uid())');
      v_check := replace(v_check, '"auth"."role"()', '(SELECT auth.role())');
      v_check := replace(v_check, 'auth.role()', '(SELECT auth.role())');
      v_check := replace(v_check, '"auth"."email"()', '(SELECT auth.email())');
      v_check := replace(v_check, 'auth.email()', '(SELECT auth.email())');
      v_check := regexp_replace(v_check, '"current_setting"\(([^()]*)\)', '(SELECT current_setting(\1))', 'g');
      v_check := regexp_replace(v_check, 'current_setting\(([^()]*)\)', '(SELECT current_setting(\1))', 'g');
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);

    v_sql := format(
      'CREATE POLICY %I ON public.%I AS %s FOR %s TO %s',
      pol.policyname,
      pol.tablename,
      pol.permissive,
      pol.cmd,
      v_roles
    );

    IF v_qual IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_qual);
    END IF;

    IF v_check IS NOT NULL THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_sql;
  END LOOP;
END
$$;

-- Keep uq_elite_interest_email_lower, created with the table definition.
DROP INDEX IF EXISTS public.elite_interest_email_unique;

-- Keep idx_entitlements_user_id, added by the FK-index cleanup migration.
DROP INDEX IF EXISTS public.idx_entitlements_user;

COMMIT;
