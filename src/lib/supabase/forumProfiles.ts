import { supabase } from './client';
import type { ReputationRankTier } from './types';

export interface ForumPublicProfileRow {
  user_id: string;
  username: string | null;
  avatar_url: string | null;
  producer_tier: string | null;
  xp: number;
  level: number;
  rank_tier: ReputationRankTier;
  reputation_score: number;
  created_at: string;
  updated_at: string;
}

export async function fetchForumPublicProfilesMap(
  userIds: Array<string | null | undefined>
): Promise<Map<string, ForumPublicProfileRow>> {
  const uniqueIds = [...new Set(userIds.filter((value): value is string => typeof value === 'string' && value.length > 0))];

  if (uniqueIds.length === 0) {
    return new Map();
  }

  const { data, error } = await supabase
    .from('forum_public_profiles' as any)
    .select('user_id, username, avatar_url, producer_tier, xp, level, rank_tier, reputation_score, created_at, updated_at')
    .in('user_id', uniqueIds);

  if (error) {
    throw error;
  }

  const rows = (data as unknown as ForumPublicProfileRow[] | null) ?? [];
  return new Map(rows.map((row) => [row.user_id, row]));
}
