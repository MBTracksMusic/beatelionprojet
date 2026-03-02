import { Award, Sparkles } from 'lucide-react';
import { Badge } from '../ui/Badge';
import type { ReputationRankTier } from '../../lib/supabase/types';

const rankLabels: Record<ReputationRankTier, string> = {
  bronze: 'Bronze',
  silver: 'Silver',
  gold: 'Gold',
  platinum: 'Platinum',
  diamond: 'Diamond',
};

const rankVariant: Record<ReputationRankTier, 'default' | 'info' | 'premium' | 'success'> = {
  bronze: 'default',
  silver: 'info',
  gold: 'premium',
  platinum: 'info',
  diamond: 'success',
};

export function formatRankTier(rankTier?: ReputationRankTier | null) {
  return rankTier ? rankLabels[rankTier] : 'Bronze';
}

interface ReputationBadgeProps {
  rankTier?: ReputationRankTier | null;
  level?: number | null;
  xp?: number | null;
  compact?: boolean;
}

export function ReputationBadge({ rankTier = 'bronze', level = 1, xp, compact = false }: ReputationBadgeProps) {
  const normalizedRankTier = rankTier ?? 'bronze';

  return (
    <div className={`flex flex-wrap items-center gap-2 ${compact ? '' : 'mt-1'}`}>
      <Badge variant={rankVariant[normalizedRankTier]} className={compact ? '' : 'text-[11px]'}>
        <Award className="h-3 w-3" />
        {formatRankTier(normalizedRankTier)}
      </Badge>
      <Badge variant="default" className={compact ? '' : 'text-[11px]'}>
        <Sparkles className="h-3 w-3" />
        Niveau {level ?? 1}
      </Badge>
      {!compact && typeof xp === 'number' && (
        <span className="text-[11px] text-zinc-500">{xp} XP</span>
      )}
    </div>
  );
}
