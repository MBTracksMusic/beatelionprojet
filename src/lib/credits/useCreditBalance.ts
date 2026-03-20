import { useCallback, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';

export function useCreditBalance(userId?: string) {
  const [balance, setBalance] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refetch = useCallback(async () => {
    if (!userId) {
      setBalance(null);
      setError(null);
      setIsLoading(false);
      return null;
    }

    setIsLoading(true);
    setError(null);

    try {
      const { data, error: rpcError } = await supabase.rpc('get_my_credit_balance');

      if (rpcError) {
        throw rpcError;
      }

      const nextBalance = typeof data === 'number' ? data : 0;

      setBalance(nextBalance);
      return nextBalance;
    } catch (fetchError) {
      const message = fetchError instanceof Error ? fetchError.message : 'credit_balance_load_failed';
      setError(message);
      setBalance(null);
      return null;
    } finally {
      setIsLoading(false);
    }
  }, [userId]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  return {
    balance,
    isLoading,
    error,
    refetch,
  };
}
