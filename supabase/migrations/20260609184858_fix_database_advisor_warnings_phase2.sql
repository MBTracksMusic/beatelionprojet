-- Phase 2: collapse equivalent permissive RLS policies flagged by Supabase
-- Database Advisor. The migration rebuilds policies from pg_policies so the
-- existing predicates stay authoritative and business rules remain unchanged.

BEGIN;

DO $$
DECLARE
  v_group record;
  v_copy record;
  v_split record;
  v_source record;
  v_roles text;
  v_qual text;
  v_check text;
  v_sql text;
  v_command text;
BEGIN
  CREATE TEMP TABLE _policy_cache ON COMMIT DROP AS
  SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    upper(cmd) AS cmd,
    roles::text[] AS roles,
    qual,
    with_check
  FROM pg_policies
  WHERE schemaname = 'public';

  CREATE TEMP TABLE _policy_groups (
    tablename text NOT NULL,
    command text NOT NULL,
    role_names text[] NOT NULL,
    new_policy_name text NOT NULL,
    policy_names text[] NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _policy_groups (tablename, command, role_names, new_policy_name, policy_names)
  VALUES
    ('admin_battle_applications', 'SELECT', ARRAY['authenticated'], 'Advisor admin battle applications select', ARRAY[
      'Admins can manage admin battle applications',
      'Producers can read own admin battle applications'
    ]),
    ('admin_battle_campaigns', 'SELECT', ARRAY['authenticated'], 'Advisor admin battle campaigns select', ARRAY[
      'Admins can manage admin battle campaigns',
      'Public can read open battle campaigns'
    ]),
    ('app_settings', 'SELECT', ARRAY['authenticated'], 'Advisor app settings select', ARRAY[
      'Admins can read all app settings',
      'Public can read safe app settings'
    ]),
    ('battle_comments', 'SELECT', ARRAY['authenticated'], 'Advisor battle comments select', ARRAY[
      'Admins can view all battle comments',
      'Anyone can view visible comments'
    ]),
    ('battle_comments', 'UPDATE', ARRAY['authenticated'], 'Advisor battle comments update', ARRAY[
      'Admins can moderate battle comments',
      'Users can update own comments'
    ]),
    ('battle_product_snapshots', 'SELECT', ARRAY['authenticated'], 'Advisor battle product snapshots select', ARRAY[
      'Admins can view all battle product snapshots',
      'Anyone can view public battle product snapshots',
      'Participants can view own battle product snapshots'
    ]),
    ('battle_votes', 'SELECT', ARRAY['authenticated'], 'Advisor battle votes select', ARRAY[
      'Admins can read all battle votes',
      'Users can read own battle votes'
    ]),
    ('battles', 'SELECT', ARRAY['authenticated'], 'Advisor battles select', ARRAY[
      'Admins can view all battles',
      'Anyone can view public battles',
      'Producers can view own battles'
    ]),
    ('battles', 'UPDATE', ARRAY['authenticated'], 'Advisor battles update', ARRAY[
      'Admins can update all battles',
      'Producers can update own pending battles'
    ]),
    ('cart_items', 'DELETE', ARRAY['authenticated'], 'Advisor cart items delete', ARRAY[
      'Users can delete their own cart items',
      'Users can remove from cart'
    ]),
    ('cart_items', 'INSERT', ARRAY['authenticated'], 'Advisor cart items insert', ARRAY[
      'Users can add to cart',
      'Users can insert their own cart items'
    ]),
    ('cart_items', 'SELECT', ARRAY['authenticated'], 'Advisor cart items select', ARRAY[
      'Users can view own cart',
      'Users can view their own cart items'
    ]),
    ('contact_messages', 'DELETE', ARRAY['authenticated'], 'Advisor contact messages delete', ARRAY[
      'Admins can delete contact messages',
      'Authenticated users can delete own closed contact messages'
    ]),
    ('contact_messages', 'SELECT', ARRAY['authenticated'], 'Advisor contact messages select', ARRAY[
      'Admins can read all contact messages',
      'Authenticated users can read own contact messages'
    ]),
    ('label_requests', 'SELECT', ARRAY['authenticated'], 'Advisor label requests select', ARRAY[
      'Admins can read label requests',
      'Users can read own label requests'
    ]),
    ('message_replies', 'SELECT', ARRAY['authenticated'], 'Advisor message replies select', ARRAY[
      'Admins can read message replies',
      'Authenticated users can read own message replies'
    ]),
    ('news_videos', 'SELECT', ARRAY['authenticated'], 'Advisor news videos select', ARRAY[
      'Admins can read all news videos',
      'Public can read published news videos'
    ]),
    ('play_events', 'SELECT', ARRAY['authenticated'], 'Advisor play events select', ARRAY[
      'Admins can read all play events',
      'Users can read their own play events'
    ]),
    ('producer_campaigns', 'SELECT', ARRAY['authenticated'], 'Advisor producer campaigns select', ARRAY[
      'Campaigns: admin write',
      'Campaigns: authenticated read'
    ]),
    ('products', 'INSERT', ARRAY['authenticated'], 'Advisor products insert', ARRAY[
      'Active producers can create products',
      'Producers can insert their own products'
    ]),
    ('products', 'SELECT', ARRAY['authenticated'], 'Advisor products select', ARRAY[
      'Authenticated users can view all products',
      'Authenticated users can view products',
      'Producers can view their own products',
      'Public can view published products'
    ]),
    ('products', 'UPDATE', ARRAY['authenticated'], 'Advisor products update', ARRAY[
      'Admins can update products',
      'Producers can update own unsold products',
      'Producers can update their own products'
    ]),
    ('purchases', 'SELECT', ARRAY['authenticated'], 'Advisor purchases select', ARRAY[
      'Admins can view all purchases',
      'Producers can view purchases of their products',
      'Producers can view sales of their products',
      'Users can view own purchases'
    ]),
    ('reputation_rules', 'SELECT', ARRAY['authenticated'], 'Advisor reputation rules select', ARRAY[
      'Admins can manage reputation rules',
      'Admins can read reputation rules'
    ]),
    ('system_settings', 'SELECT', ARRAY['authenticated'], 'Advisor system settings select', ARRAY[
      'Admins can read system settings',
      'Public can read safe settings'
    ]),
    ('user_profiles', 'SELECT', ARRAY['authenticated'], 'Advisor user profiles select', ARRAY[
      'Admins can view all profiles',
      'Admins can view all user profiles',
      'Owner can select own profile'
    ]),
    ('user_profiles', 'UPDATE', ARRAY['authenticated'], 'Advisor user profiles update', ARRAY[
      'Admins can update all user profiles',
      'Owner can update own profile'
    ]),
    ('waitlist', 'SELECT', ARRAY['authenticated'], 'Advisor waitlist select', ARRAY[
      'Admins manage waitlist',
      'User reads own waitlist entry'
    ]);

  CREATE TEMP TABLE _anon_copies (
    tablename text NOT NULL,
    source_policy text NOT NULL,
    new_policy_name text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _anon_copies (tablename, source_policy, new_policy_name)
  VALUES
    ('admin_battle_campaigns', 'Public can read open battle campaigns', 'Advisor admin battle campaigns anon select'),
    ('app_settings', 'Public can read safe app settings', 'Advisor app settings anon select'),
    ('battle_comments', 'Anyone can view visible comments', 'Advisor battle comments anon select'),
    ('battle_product_snapshots', 'Anyone can view public battle product snapshots', 'Advisor battle snapshots anon select'),
    ('battles', 'Anyone can view public battles', 'Advisor battles anon select'),
    ('news_videos', 'Public can read published news videos', 'Advisor news videos anon select'),
    ('products', 'Public can view published products', 'Advisor products anon select'),
    ('system_settings', 'Public can read safe settings', 'Advisor system settings anon select');

  CREATE TEMP TABLE _role_copies (
    tablename text NOT NULL,
    source_policy text NOT NULL,
    command text NOT NULL,
    role_names text[] NOT NULL,
    new_policy_name text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _role_copies (tablename, source_policy, command, role_names, new_policy_name)
  VALUES
    ('stripe_payout_failures', 'Service role can select all payout failures', 'SELECT', ARRAY['service_role'], 'Advisor stripe payout failures service select'),
    ('stripe_payout_failures', 'Users can view own payout failures', 'SELECT', ARRAY['authenticated'], 'Advisor stripe payout failures user select'),
    ('stripe_payout_failures', 'Service role can insert payout failures', 'INSERT', ARRAY['service_role'], 'Advisor stripe payout failures service insert'),
    ('failed_credit_allocations', 'Service role can insert failed credit allocations', 'INSERT', ARRAY['service_role'], 'Advisor failed credit allocations service insert'),
    ('failed_credit_allocations', 'Service role can select failed credit allocations', 'SELECT', ARRAY['service_role'], 'Advisor failed credit allocations service select'),
    ('failed_credit_allocations', 'Service role can update failed credit allocations', 'UPDATE', ARRAY['service_role'], 'Advisor failed credit allocations service update');

  CREATE TEMP TABLE _split_all_policies (
    tablename text NOT NULL,
    source_policy text NOT NULL,
    new_policy_prefix text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _split_all_policies (tablename, source_policy, new_policy_prefix)
  VALUES
    ('admin_battle_applications', 'Admins can manage admin battle applications', 'Advisor admin battle applications'),
    ('admin_battle_campaigns', 'Admins can manage admin battle campaigns', 'Advisor admin battle campaigns'),
    ('producer_campaigns', 'Campaigns: admin write', 'Advisor producer campaigns admin'),
    ('reputation_rules', 'Admins can manage reputation rules', 'Advisor reputation rules admin'),
    ('waitlist', 'Admins manage waitlist', 'Advisor waitlist admin');

  CREATE TEMP TABLE _drop_policies (
    tablename text NOT NULL,
    policyname text NOT NULL,
    PRIMARY KEY (tablename, policyname)
  ) ON COMMIT DROP;

  INSERT INTO _drop_policies (tablename, policyname)
  SELECT DISTINCT tablename, unnest(policy_names)
  FROM _policy_groups
  ON CONFLICT DO NOTHING;

  INSERT INTO _drop_policies (tablename, policyname)
  SELECT DISTINCT tablename, source_policy
  FROM _anon_copies
  ON CONFLICT DO NOTHING;

  INSERT INTO _drop_policies (tablename, policyname)
  SELECT DISTINCT tablename, source_policy
  FROM _role_copies
  ON CONFLICT DO NOTHING;

  INSERT INTO _drop_policies (tablename, policyname)
  SELECT DISTINCT tablename, source_policy
  FROM _split_all_policies
  ON CONFLICT DO NOTHING;

  -- Preserve existing anonymous read access separately before authenticated
  -- policies are merged.
  FOR v_copy IN
    SELECT a.*, p.permissive, p.qual
    FROM _anon_copies a
    JOIN _policy_cache p
      ON p.tablename = a.tablename
     AND p.policyname = a.source_policy
     AND p.cmd IN ('SELECT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_copy.new_policy_name, v_copy.tablename);

    v_sql := format(
      'CREATE POLICY %I ON public.%I AS %s FOR SELECT TO anon',
      v_copy.new_policy_name,
      v_copy.tablename,
      v_copy.permissive
    );

    IF v_copy.qual IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_copy.qual);
    END IF;

    EXECUTE v_sql;
  END LOOP;

  -- Recreate service-role and authenticated owner policies with explicit role
  -- targets so public database roles no longer receive those policies.
  FOR v_copy IN
    SELECT r.*, p.permissive, p.qual, p.with_check
    FROM _role_copies r
    JOIN _policy_cache p
      ON p.tablename = r.tablename
     AND p.policyname = r.source_policy
     AND p.cmd IN (r.command, 'ALL')
  LOOP
    SELECT string_agg(
      CASE WHEN role_name = 'public' THEN 'PUBLIC' ELSE quote_ident(role_name) END,
      ', '
      ORDER BY role_name
    )
    INTO v_roles
    FROM unnest(v_copy.role_names) AS r(role_name);

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_copy.new_policy_name, v_copy.tablename);

    v_sql := format(
      'CREATE POLICY %I ON public.%I AS %s FOR %s TO %s',
      v_copy.new_policy_name,
      v_copy.tablename,
      v_copy.permissive,
      v_copy.command,
      v_roles
    );

    IF v_copy.command IN ('SELECT', 'UPDATE', 'DELETE') AND v_copy.qual IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_copy.qual);
    END IF;

    IF v_copy.command = 'INSERT' THEN
      v_check := COALESCE(v_copy.with_check, v_copy.qual);
    ELSIF v_copy.command = 'UPDATE' THEN
      v_check := COALESCE(v_copy.with_check, v_copy.qual);
    ELSE
      v_check := NULL;
    END IF;

    IF v_check IS NOT NULL AND v_copy.command IN ('INSERT', 'UPDATE') THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_sql;
  END LOOP;

  -- Policies declared FOR ALL were part of SELECT duplicates. Split their
  -- write-side behavior out, then let the SELECT part be handled by the merged
  -- authenticated policy.
  FOR v_split IN
    SELECT s.*, p.permissive, p.roles, p.qual, p.with_check
    FROM _split_all_policies s
    JOIN _policy_cache p
      ON p.tablename = s.tablename
     AND p.policyname = s.source_policy
     AND p.cmd = 'ALL'
  LOOP
    SELECT string_agg(
      CASE WHEN role_name = 'public' THEN 'PUBLIC' ELSE quote_ident(role_name) END,
      ', '
      ORDER BY role_name
    )
    INTO v_roles
    FROM unnest(v_split.roles) AS r(role_name);

    FOREACH v_command IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE']
    LOOP
      EXECUTE format(
        'DROP POLICY IF EXISTS %I ON public.%I',
        v_split.new_policy_prefix || ' ' || lower(v_command),
        v_split.tablename
      );

      v_sql := format(
        'CREATE POLICY %I ON public.%I AS %s FOR %s TO %s',
        v_split.new_policy_prefix || ' ' || lower(v_command),
        v_split.tablename,
        v_split.permissive,
        v_command,
        v_roles
      );

      IF v_command IN ('UPDATE', 'DELETE') AND v_split.qual IS NOT NULL THEN
        v_sql := v_sql || format(' USING (%s)', v_split.qual);
      END IF;

      IF v_command IN ('INSERT', 'UPDATE') THEN
        v_check := COALESCE(v_split.with_check, v_split.qual);
      ELSE
        v_check := NULL;
      END IF;

      IF v_check IS NOT NULL THEN
        v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
      END IF;

      EXECUTE v_sql;
    END LOOP;
  END LOOP;

  -- Create one authenticated policy per table/action with an OR of the old
  -- predicates. This keeps the same allowed cases with a single permissive
  -- policy evaluation for the authenticated role.
  FOR v_group IN SELECT * FROM _policy_groups
  LOOP
    SELECT string_agg(
      CASE WHEN role_name = 'public' THEN 'PUBLIC' ELSE quote_ident(role_name) END,
      ', '
      ORDER BY role_name
    )
    INTO v_roles
    FROM unnest(v_group.role_names) AS r(role_name);

    IF v_group.command IN ('SELECT', 'UPDATE', 'DELETE') THEN
      SELECT string_agg(format('(%s)', p.qual), ' OR ' ORDER BY array_position(v_group.policy_names, p.policyname))
      INTO v_qual
      FROM _policy_cache p
      WHERE p.tablename = v_group.tablename
        AND p.policyname = ANY(v_group.policy_names)
        AND p.cmd IN (v_group.command, 'ALL')
        AND p.qual IS NOT NULL;
    ELSE
      v_qual := NULL;
    END IF;

    IF v_group.command = 'INSERT' THEN
      SELECT string_agg(format('(%s)', COALESCE(p.with_check, p.qual)), ' OR ' ORDER BY array_position(v_group.policy_names, p.policyname))
      INTO v_check
      FROM _policy_cache p
      WHERE p.tablename = v_group.tablename
        AND p.policyname = ANY(v_group.policy_names)
        AND p.cmd IN (v_group.command, 'ALL')
        AND COALESCE(p.with_check, p.qual) IS NOT NULL;
    ELSIF v_group.command = 'UPDATE' THEN
      SELECT string_agg(format('(%s)', COALESCE(p.with_check, p.qual)), ' OR ' ORDER BY array_position(v_group.policy_names, p.policyname))
      INTO v_check
      FROM _policy_cache p
      WHERE p.tablename = v_group.tablename
        AND p.policyname = ANY(v_group.policy_names)
        AND p.cmd IN (v_group.command, 'ALL')
        AND COALESCE(p.with_check, p.qual) IS NOT NULL;
    ELSE
      v_check := NULL;
    END IF;

    IF v_group.command IN ('SELECT', 'UPDATE', 'DELETE') AND v_qual IS NULL THEN
      RAISE NOTICE 'Skipping policy %, no USING predicates found', v_group.new_policy_name;
      CONTINUE;
    END IF;

    IF v_group.command IN ('INSERT', 'UPDATE') AND v_check IS NULL THEN
      RAISE NOTICE 'Skipping policy %, no WITH CHECK predicates found', v_group.new_policy_name;
      CONTINUE;
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_group.new_policy_name, v_group.tablename);

    v_sql := format(
      'CREATE POLICY %I ON public.%I AS PERMISSIVE FOR %s TO %s',
      v_group.new_policy_name,
      v_group.tablename,
      v_group.command,
      v_roles
    );

    IF v_qual IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_qual);
    END IF;

    IF v_check IS NOT NULL AND v_group.command IN ('INSERT', 'UPDATE') THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_sql;
  END LOOP;

  FOR v_source IN SELECT * FROM _drop_policies
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_source.policyname, v_source.tablename);
  END LOOP;
END $$;

COMMIT;
