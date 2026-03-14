/*
  # Harden public read access for admin battle campaigns

  Why:
  - Public SELECT policy on the base table exposed all columns to anon/authenticated.
  - Public pages only need a subset of campaign fields.

  What:
  - Remove broad public SELECT policy from public.admin_battle_campaigns.
  - Expose a limited public view with safe campaign fields.
*/

BEGIN;

DROP POLICY IF EXISTS "Anyone can read admin battle campaigns" ON public.admin_battle_campaigns;

DROP VIEW IF EXISTS public.admin_battle_campaigns_public;
CREATE VIEW public.admin_battle_campaigns_public AS
SELECT
  id,
  title,
  description,
  social_description,
  cover_image_url,
  share_slug,
  status,
  participation_deadline,
  submission_deadline,
  battle_id,
  created_at,
  updated_at
FROM public.admin_battle_campaigns
WHERE status IN ('applications_open', 'selection_locked', 'launched');

REVOKE ALL ON TABLE public.admin_battle_campaigns_public FROM PUBLIC;
REVOKE ALL ON TABLE public.admin_battle_campaigns_public FROM anon;
REVOKE ALL ON TABLE public.admin_battle_campaigns_public FROM authenticated;
GRANT SELECT ON TABLE public.admin_battle_campaigns_public TO anon;
GRANT SELECT ON TABLE public.admin_battle_campaigns_public TO authenticated;

COMMIT;
