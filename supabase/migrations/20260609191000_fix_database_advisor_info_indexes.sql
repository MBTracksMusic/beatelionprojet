-- Phase 3: fix low-risk Database Advisor INFO rows.
-- Adds covering indexes for foreign keys flagged by the Advisor and adds a
-- primary key to public.v_days only when existing data is compatible.

BEGIN;

DO $$
DECLARE
  v_fk record;
  v_index_name text;
  v_columns text;
  v_has_covering_index boolean;
BEGIN
  CREATE TEMP TABLE _advisor_unindexed_fkeys (
    fkey_name text PRIMARY KEY
  ) ON COMMIT DROP;

  INSERT INTO _advisor_unindexed_fkeys (fkey_name)
  VALUES
    ('access_whitelist_granted_by_fkey'),
    ('access_whitelist_user_id_fkey'),
    ('admin_battle_applications_proposed_product_id_fkey'),
    ('admin_battle_campaigns_battle_id_fkey'),
    ('admin_battle_campaigns_created_by_fkey'),
    ('admin_battle_campaigns_selected_producer1_id_fkey'),
    ('admin_battle_campaigns_selected_producer2_id_fkey'),
    ('ai_admin_actions_executed_by_fkey'),
    ('ai_training_feedback_created_by_fkey'),
    ('battle_comments_parent_id_fkey'),
    ('battle_share_events_reputation_event_id_fkey'),
    ('battle_vote_feedback_user_id_fkey'),
    ('battles_genre_id_fkey'),
    ('credit_purchase_claims_license_id_fkey'),
    ('credit_purchase_claims_product_id_fkey'),
    ('event_bus_user_id_fkey'),
    ('event_outbox_replayed_from_event_id_fkey'),
    ('event_replay_requests_requested_by_fkey'),
    ('event_replay_requests_user_id_fkey'),
    ('exclusive_locks_user_id_fkey'),
    ('forum_assistant_jobs_source_post_id_fkey'),
    ('forum_assistant_jobs_topic_id_fkey'),
    ('forum_likes_user_id_fkey'),
    ('forum_moderation_logs_reviewed_by_fkey'),
    ('forum_posts_source_post_id_fkey'),
    ('forum_topics_deleted_by_fkey'),
    ('label_requests_reviewed_by_fkey'),
    ('monitoring_alert_events_resolved_by_fkey'),
    ('products_watermark_profile_id_fkey'),
    ('security_events_user_id_fkey');

  FOR v_fk IN
    SELECT
      c.oid AS constraint_oid,
      c.conname,
      c.conrelid,
      c.conkey,
      n.nspname AS schema_name,
      r.relname AS table_name
    FROM pg_constraint c
    JOIN _advisor_unindexed_fkeys f
      ON f.fkey_name = c.conname
    JOIN pg_class r
      ON r.oid = c.conrelid
    JOIN pg_namespace n
      ON n.oid = r.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname = 'public'
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM pg_index i
      WHERE i.indrelid = v_fk.conrelid
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND (
          SELECT array_agg(k.attnum::smallint ORDER BY k.ordinality)
          FROM unnest(i.indkey::smallint[]) WITH ORDINALITY AS k(attnum, ordinality)
          WHERE k.ordinality <= array_length(v_fk.conkey, 1)
        ) = v_fk.conkey
    )
    INTO v_has_covering_index;

    IF v_has_covering_index THEN
      CONTINUE;
    END IF;

    SELECT string_agg(format('%I', a.attname), ', ' ORDER BY ck.ordinality)
    INTO v_columns
    FROM unnest(v_fk.conkey) WITH ORDINALITY AS ck(attnum, ordinality)
    JOIN pg_attribute a
      ON a.attrelid = v_fk.conrelid
     AND a.attnum = ck.attnum;

    IF v_columns IS NULL THEN
      RAISE NOTICE 'Skipping %, no FK columns found', v_fk.conname;
      CONTINUE;
    END IF;

    v_index_name := left(
      'idx_advisor_fk_' || regexp_replace(v_fk.conname, '_fkey$', ''),
      54
    ) || '_' || substr(md5(v_fk.conname), 1, 8);

    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I ON %I.%I (%s)',
      v_index_name,
      v_fk.schema_name,
      v_fk.table_name,
      v_columns
    );
  END LOOP;
END $$;

DO $$
DECLARE
  v_has_table boolean;
  v_has_column boolean;
  v_has_primary_key boolean;
  v_has_nulls boolean;
  v_has_duplicates boolean;
BEGIN
  SELECT to_regclass('public.v_days') IS NOT NULL INTO v_has_table;

  IF NOT v_has_table THEN
    RAISE NOTICE 'Relation public.v_days not found; skipped primary key.';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'v_days'
      AND column_name = 'coalesce'
  )
  INTO v_has_column;

  IF NOT v_has_column THEN
    RAISE NOTICE 'Column public.v_days.coalesce not found; skipped primary key.';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_index
    WHERE indrelid = 'public.v_days'::regclass
      AND indisprimary
  )
  INTO v_has_primary_key;

  IF v_has_primary_key THEN
    RETURN;
  END IF;

  EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.v_days WHERE "coalesce" IS NULL)'
  INTO v_has_nulls;

  EXECUTE '
    SELECT EXISTS (
      SELECT 1
      FROM public.v_days
      GROUP BY "coalesce"
      HAVING count(*) > 1
    )
  '
  INTO v_has_duplicates;

  IF v_has_nulls OR v_has_duplicates THEN
    RAISE NOTICE
      'Skipped primary key on public.v_days because existing data has nulls (%) or duplicates (%).',
      v_has_nulls,
      v_has_duplicates;
    RETURN;
  END IF;

  ALTER TABLE public.v_days ALTER COLUMN "coalesce" SET NOT NULL;
  ALTER TABLE public.v_days ADD CONSTRAINT v_days_pkey PRIMARY KEY ("coalesce");
END $$;

COMMIT;
