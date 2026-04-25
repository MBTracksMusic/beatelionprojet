/*
  # Enforce Label Announcements category rules

  The category must be restricted by subscription/verified-label access only.
  It should not inherit a rank gate from an earlier admin edit or seed.
*/

BEGIN;

UPDATE public.forum_categories
SET name = 'Annonces Label',
    description = 'Recherches et briefs des labels visibles uniquement par les producteurs abonnes.',
    is_premium_only = true,
    xp_multiplier = 1,
    moderation_strictness = 'high',
    is_competitive = false,
    required_rank_tier = NULL,
    allow_links = true,
    allow_media = true
WHERE slug = 'annonces-label';

COMMIT;
