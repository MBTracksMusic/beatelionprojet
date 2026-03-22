import { supabase } from '@/lib/supabase/client';
import { useAuthStore } from './auth/store';

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type InteractionAction = 'play' | 'pause' | 'complete' | 'like' | 'add_to_cart';

export function isTrackableBeatId(beatId: string) {
  return UUID_REGEX.test(beatId);
}

export async function trackInteraction({
  beatId,
  action,
  duration,
  userId,
}: {
  beatId: string;
  action: InteractionAction;
  duration?: number;
  userId?: string | null;
}) {
  if (!beatId || !isTrackableBeatId(beatId)) {
    return;
  }

  const resolvedDuration =
    typeof duration === 'number' && Number.isFinite(duration)
      ? Math.max(0, Math.round(duration))
      : null;

  const resolvedUserId = userId ?? useAuthStore.getState().user?.id ?? null;

  try {
    const { error } = await supabase.from('user_interactions' as any).insert({
      beat_id: beatId,
      action_type: action,
      duration: resolvedDuration,
      user_id: resolvedUserId,
    });

    if (error) {
      throw error;
    }
  } catch (err) {
    console.error('Tracking error', err);
  }
}
