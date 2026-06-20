-- Normalize newly introduced style campaign slot defaults.
-- Only empty style campaigns are touched, so existing populated campaigns keep
-- their explicit admin capacity.

WITH style_campaign_defaults(type, default_max_slots) AS (
  VALUES
    ('style_trap', 10),
    ('style_drill', 10),
    ('style_afrobeat', 10),
    ('style_amapiano', 10),
    ('style_boom_bap', 10),
    ('style_rnb', 10),
    ('style_pop_urban', 10),
    ('style_reggaeton', 10),
    ('style_dancehall', 10),
    ('style_house', 10),
    ('style_electro', 10),
    ('style_lofi', 10),
    ('style_cinematic', 10),
    ('style_custom', 10)
)
UPDATE public.producer_campaigns AS pc
SET max_slots = defaults.default_max_slots
FROM style_campaign_defaults AS defaults
WHERE pc.type = defaults.type
  AND pc.max_slots IS DISTINCT FROM defaults.default_max_slots
  AND NOT EXISTS (
    SELECT 1
    FROM public.user_profiles AS up
    WHERE up.producer_campaign_type = pc.type
  );
