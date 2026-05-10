-- Add pricing_producer_promo JSONB column to settings.
-- Shape: { enabled: boolean, title: string, message: string, button_label: string, campaign_type: string }
-- NULL = feature never configured (treated as disabled on the frontend).
ALTER TABLE public.settings
  ADD COLUMN IF NOT EXISTS pricing_producer_promo jsonb DEFAULT NULL;

-- Add campaign_type to waitlist so promo-card entries are distinguishable from
-- organic waitlist entries without needing to parse the source field.
ALTER TABLE public.waitlist
  ADD COLUMN IF NOT EXISTS campaign_type text DEFAULT NULL;
