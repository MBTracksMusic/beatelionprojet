export const FOUNDING_PRODUCER_CAMPAIGN_TYPE = 'founding';

export const PRODUCER_CAMPAIGN_TYPES = [
  {
    type: FOUNDING_PRODUCER_CAMPAIGN_TYPE,
    label: 'Founding Producers',
    category: 'general',
    description: 'Campagne principale pour faire entrer les producteurs fondateurs.',
  },
  {
    type: 'style_trap',
    label: 'Style Trap',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Trap.',
  },
  {
    type: 'style_drill',
    label: 'Style Drill',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Drill.',
  },
  {
    type: 'style_afrobeat',
    label: 'Style Afrobeat',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Afrobeat.',
  },
  {
    type: 'style_amapiano',
    label: 'Style Amapiano',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Amapiano.',
  },
  {
    type: 'style_boom_bap',
    label: 'Style Boom Bap',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Boom Bap.',
  },
  {
    type: 'style_rnb',
    label: 'Style R&B',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs R&B.',
  },
  {
    type: 'style_pop_urban',
    label: 'Style Pop urbaine',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Pop urbaine.',
  },
  {
    type: 'style_reggaeton',
    label: 'Style Reggaeton',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Reggaeton.',
  },
  {
    type: 'style_dancehall',
    label: 'Style Dancehall',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Dancehall.',
  },
  {
    type: 'style_house',
    label: 'Style House',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs House.',
  },
  {
    type: 'style_electro',
    label: 'Style Electro',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Electro.',
  },
  {
    type: 'style_lofi',
    label: 'Style Lo-fi',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs Lo-fi.',
  },
  {
    type: 'style_cinematic',
    label: 'Style Cinematic',
    category: 'style',
    description: 'Campagne selective pour recruter des producteurs cinematic / trailer.',
  },
  {
    type: 'style_custom',
    label: 'Style Custom',
    category: 'style',
    description: 'Campagne selective temporaire ou sur mesure.',
  },
] as const;

export type ProducerCampaignType = (typeof PRODUCER_CAMPAIGN_TYPES)[number]['type'];

export const getProducerCampaignTypeMeta = (type: string) =>
  PRODUCER_CAMPAIGN_TYPES.find((campaignType) => campaignType.type === type) ?? null;
