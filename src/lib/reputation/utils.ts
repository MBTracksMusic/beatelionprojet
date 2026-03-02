import type { ReputationRankTier } from '../supabase/types';

const rankValues: Record<ReputationRankTier, number> = {
  bronze: 1,
  silver: 2,
  gold: 3,
  platinum: 4,
  diamond: 5,
};

export function rankTierValue(rankTier?: ReputationRankTier | null) {
  return rankTier ? rankValues[rankTier] : rankValues.bronze;
}

export function meetsRankRequirement(
  currentRankTier?: ReputationRankTier | null,
  requiredRankTier?: ReputationRankTier | null,
) {
  if (!requiredRankTier) return true;
  return rankTierValue(currentRankTier) >= rankTierValue(requiredRankTier);
}
