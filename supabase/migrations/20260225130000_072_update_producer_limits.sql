/*
  # Update PRODUCTEUR limits and add ELITE interest tracking

  - PRODUCTEUR (tier = 'pro'):
    - max_beats_published = 10
    - max_battles_created_per_month = 3
  - Add public.elite_interest for "M'informer du lancement" tracking
    - insert allowed for anon/authenticated
    - select denied for public roles
*/

BEGIN;

UPDATE public.producer_plans
SET
  max_beats_published = 10,
  max_battles_created_per_month = 3,
  updated_at = now()
WHERE tier = 'pro'::public.producer_tier_type;

CREATE TABLE IF NOT EXISTS public.elite_interest (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_elite_interest_email_lower
  ON public.elite_interest (lower(email));

ALTER TABLE public.elite_interest ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.elite_interest FROM PUBLIC;
REVOKE ALL ON TABLE public.elite_interest FROM anon;
REVOKE ALL ON TABLE public.elite_interest FROM authenticated;

GRANT INSERT ON TABLE public.elite_interest TO anon;
GRANT INSERT ON TABLE public.elite_interest TO authenticated;
GRANT INSERT ON TABLE public.elite_interest TO service_role;
GRANT SELECT ON TABLE public.elite_interest TO service_role;

DROP POLICY IF EXISTS "Elite interest insertable" ON public.elite_interest;
CREATE POLICY "Elite interest insertable"
  ON public.elite_interest
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (
    length(trim(email)) > 3
  );

COMMIT;
