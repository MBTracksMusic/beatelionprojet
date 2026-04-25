/*
  # Fix forum category admin update RPC ambiguity

  The update branch of `forum_admin_upsert_category` used `WHERE id = p_category_id`.
  Because the function returns a table with an output column named `id`, PL/pgSQL
  treats that reference as ambiguous and the admin UI shows "Enregistrement impossible".

  This migration keeps the existing behavior and qualifies the update target alias.
*/

BEGIN;

CREATE OR REPLACE FUNCTION public.forum_admin_upsert_category(
  p_category_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_slug text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_position integer DEFAULT NULL,
  p_is_premium_only boolean DEFAULT false,
  p_xp_multiplier numeric DEFAULT 1,
  p_moderation_strictness text DEFAULT 'normal',
  p_is_competitive boolean DEFAULT false,
  p_required_rank_tier text DEFAULT NULL,
  p_allow_links boolean DEFAULT true,
  p_allow_media boolean DEFAULT true
)
RETURNS TABLE (
  id uuid,
  name text,
  slug text,
  description text,
  is_premium_only boolean,
  "position" integer,
  xp_multiplier numeric,
  moderation_strictness text,
  is_competitive boolean,
  required_rank_tier text,
  allow_links boolean,
  allow_media boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_jwt_role text := COALESCE(auth.jwt()->>'role', current_setting('request.jwt.claim.role', true), '');
  v_row public.forum_categories%ROWTYPE;
  v_effective_slug text := COALESCE(NULLIF(btrim(COALESCE(p_slug, '')), ''), NULLIF(btrim(COALESCE(p_name, '')), ''));
  v_effective_position integer := COALESCE(
    p_position,
    (SELECT COALESCE(max(fc.position), -1) + 1 FROM public.forum_categories fc)
  );
BEGIN
  IF NOT (v_jwt_role = 'service_role' OR public.is_admin(v_actor)) THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required';
  END IF;

  IF v_effective_slug IS NULL OR btrim(v_effective_slug) = '' THEN
    RAISE EXCEPTION 'slug_required';
  END IF;

  IF p_moderation_strictness NOT IN ('low', 'normal', 'high') THEN
    RAISE EXCEPTION 'invalid_moderation_strictness';
  END IF;

  IF p_required_rank_tier IS NOT NULL AND p_required_rank_tier NOT IN ('bronze', 'silver', 'gold', 'platinum', 'diamond') THEN
    RAISE EXCEPTION 'invalid_required_rank_tier';
  END IF;

  IF p_category_id IS NULL THEN
    INSERT INTO public.forum_categories (
      name,
      slug,
      description,
      position,
      is_premium_only,
      xp_multiplier,
      moderation_strictness,
      is_competitive,
      required_rank_tier,
      allow_links,
      allow_media
    )
    VALUES (
      btrim(p_name),
      btrim(v_effective_slug),
      NULLIF(btrim(COALESCE(p_description, '')), ''),
      GREATEST(0, v_effective_position),
      COALESCE(p_is_premium_only, false),
      GREATEST(COALESCE(p_xp_multiplier, 1), 0.1),
      p_moderation_strictness,
      COALESCE(p_is_competitive, false),
      p_required_rank_tier,
      COALESCE(p_allow_links, true),
      COALESCE(p_allow_media, true)
    )
    RETURNING * INTO v_row;

    PERFORM public.log_admin_action_audit(
      p_admin_user_id => v_actor,
      p_action_type => 'forum_category_create',
      p_entity_type => 'forum_category',
      p_entity_id => v_row.id,
      p_source => 'rpc',
      p_context => jsonb_build_object(
        'slug', v_row.slug,
        'name', v_row.name
      ),
      p_extra_details => jsonb_build_object(
        'is_premium_only', v_row.is_premium_only,
        'is_competitive', v_row.is_competitive,
        'required_rank_tier', v_row.required_rank_tier,
        'xp_multiplier', v_row.xp_multiplier,
        'moderation_strictness', v_row.moderation_strictness,
        'allow_links', v_row.allow_links,
        'allow_media', v_row.allow_media
      ),
      p_success => true,
      p_error => NULL
    );
  ELSE
    UPDATE public.forum_categories AS fc
    SET name = btrim(p_name),
        slug = btrim(v_effective_slug),
        description = NULLIF(btrim(COALESCE(p_description, '')), ''),
        position = GREATEST(0, v_effective_position),
        is_premium_only = COALESCE(p_is_premium_only, false),
        xp_multiplier = GREATEST(COALESCE(p_xp_multiplier, 1), 0.1),
        moderation_strictness = p_moderation_strictness,
        is_competitive = COALESCE(p_is_competitive, false),
        required_rank_tier = p_required_rank_tier,
        allow_links = COALESCE(p_allow_links, true),
        allow_media = COALESCE(p_allow_media, true)
    WHERE fc.id = p_category_id
    RETURNING fc.* INTO v_row;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'category_not_found';
    END IF;

    PERFORM public.log_admin_action_audit(
      p_admin_user_id => v_actor,
      p_action_type => 'forum_category_update',
      p_entity_type => 'forum_category',
      p_entity_id => v_row.id,
      p_source => 'rpc',
      p_context => jsonb_build_object(
        'slug', v_row.slug,
        'name', v_row.name
      ),
      p_extra_details => jsonb_build_object(
        'is_premium_only', v_row.is_premium_only,
        'is_competitive', v_row.is_competitive,
        'required_rank_tier', v_row.required_rank_tier,
        'xp_multiplier', v_row.xp_multiplier,
        'moderation_strictness', v_row.moderation_strictness,
        'allow_links', v_row.allow_links,
        'allow_media', v_row.allow_media
      ),
      p_success => true,
      p_error => NULL
    );
  END IF;

  RETURN QUERY
  SELECT
    v_row.id,
    v_row.name,
    v_row.slug,
    v_row.description,
    v_row.is_premium_only,
    v_row.position AS "position",
    v_row.xp_multiplier,
    v_row.moderation_strictness,
    v_row.is_competitive,
    v_row.required_rank_tier,
    v_row.allow_links,
    v_row.allow_media,
    v_row.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.forum_admin_upsert_category(uuid, text, text, text, integer, boolean, numeric, text, boolean, text, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.forum_admin_upsert_category(uuid, text, text, text, integer, boolean, numeric, text, boolean, text, boolean, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.forum_admin_upsert_category(uuid, text, text, text, integer, boolean, numeric, text, boolean, text, boolean, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_upsert_category(uuid, text, text, text, integer, boolean, numeric, text, boolean, text, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.forum_admin_upsert_category(uuid, text, text, text, integer, boolean, numeric, text, boolean, text, boolean, boolean) TO service_role;

COMMIT;
