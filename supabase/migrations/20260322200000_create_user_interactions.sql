CREATE TABLE IF NOT EXISTS public.user_interactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  beat_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  action_type text NOT NULL,
  duration integer NULL CHECK (duration IS NULL OR duration >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_interactions_user
  ON public.user_interactions(user_id);

CREATE INDEX IF NOT EXISTS idx_user_interactions_beat
  ON public.user_interactions(beat_id);

ALTER TABLE public.user_interactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anonymous users can insert anonymous interactions" ON public.user_interactions;
CREATE POLICY "Anonymous users can insert anonymous interactions"
ON public.user_interactions
FOR INSERT
TO anon
WITH CHECK (user_id IS NULL);

DROP POLICY IF EXISTS "Authenticated users can insert own interactions" ON public.user_interactions;
CREATE POLICY "Authenticated users can insert own interactions"
ON public.user_interactions
FOR INSERT
TO authenticated
WITH CHECK (user_id IS NULL OR user_id = auth.uid());

REVOKE ALL ON TABLE public.user_interactions FROM PUBLIC;
GRANT INSERT ON TABLE public.user_interactions TO anon;
GRANT INSERT ON TABLE public.user_interactions TO authenticated;
GRANT SELECT ON TABLE public.user_interactions TO service_role;
