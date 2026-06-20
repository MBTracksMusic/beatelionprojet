-- Seed official producer campaign types.
-- Existing admin changes to max_slots and is_active are intentionally preserved.

INSERT INTO public.producer_campaigns (type, label, trial_duration, max_slots, is_active)
VALUES
  ('style_trap', 'Style Trap', interval '3 months', 10, false),
  ('style_drill', 'Style Drill', interval '3 months', 10, false),
  ('style_afrobeat', 'Style Afrobeat', interval '3 months', 10, false),
  ('style_amapiano', 'Style Amapiano', interval '3 months', 10, false),
  ('style_boom_bap', 'Style Boom Bap', interval '3 months', 10, false),
  ('style_rnb', 'Style R&B', interval '3 months', 10, false),
  ('style_pop_urban', 'Style Pop urbaine', interval '3 months', 10, false),
  ('style_reggaeton', 'Style Reggaeton', interval '3 months', 10, false),
  ('style_dancehall', 'Style Dancehall', interval '3 months', 10, false),
  ('style_house', 'Style House', interval '3 months', 10, false),
  ('style_electro', 'Style Electro', interval '3 months', 10, false),
  ('style_lofi', 'Style Lo-fi', interval '3 months', 10, false),
  ('style_cinematic', 'Style Cinematic', interval '3 months', 10, false),
  ('style_custom', 'Style Custom', interval '3 months', 10, false)
ON CONFLICT (type) DO UPDATE
  SET
    label = EXCLUDED.label,
    trial_duration = EXCLUDED.trial_duration;
