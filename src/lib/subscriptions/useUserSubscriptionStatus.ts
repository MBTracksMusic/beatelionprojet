import { useCallback, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';
import type { SubscriptionStatus } from '../supabase/types';

interface UserSubscriptionStatusRow {
  id: string;
  plan_code: string;
  stripe_price_id: string;
  subscription_status: SubscriptionStatus;
  current_period_start: string | null;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  canceled_at: string | null;
  created_at: string;
  updated_at: string;
}

export function useUserSubscriptionStatus(userId?: string) {
  const [subscription, setSubscription] = useState<UserSubscriptionStatusRow | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refetch = useCallback(async () => {
    if (!userId) {
      setSubscription(null);
      setError(null);
      setIsLoading(false);
      return null;
    }

    setIsLoading(true);
    setError(null);

    try {
      const { data, error: rpcError } = await supabase.rpc('get_my_user_subscription_status');

      if (rpcError) {
        throw rpcError;
      }

      const nextSubscription = ((data as UserSubscriptionStatusRow[] | null) ?? [])[0] ?? null;
      setSubscription(nextSubscription);
      return nextSubscription;
    } catch (fetchError) {
      const message = fetchError instanceof Error ? fetchError.message : 'user_subscription_load_failed';
      setError(message);
      setSubscription(null);
      return null;
    } finally {
      setIsLoading(false);
    }
  }, [userId]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  const isActive = subscription?.subscription_status === 'active' || subscription?.subscription_status === 'trialing';

  return {
    subscription,
    isActive,
    isLoading,
    error,
    refetch,
  };
}
