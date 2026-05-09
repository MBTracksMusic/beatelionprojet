import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';

export type TrialStatus =
  | { status: 'loading' }
  | { status: 'subscribed' }
  | { status: 'active'; days_remaining: number }
  | { status: 'expiring_soon'; days_remaining: number }
  | { status: 'expired' }
  | { status: 'none' };

export function useTrialStatus(): TrialStatus {
  const [trialStatus, setTrialStatus] = useState<TrialStatus>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function fetchStatus() {
      const { data, error } = await supabase.rpc('get_my_trial_status');
      if (cancelled) return;
      if (error || !data) {
        setTrialStatus({ status: 'none' });
        return;
      }
      setTrialStatus(data as TrialStatus);
    }

    fetchStatus();
    return () => { cancelled = true; };
  }, []);

  return trialStatus;
}
