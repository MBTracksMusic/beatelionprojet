import { useEffect, useState } from 'react';
import { useAuth } from '../lib/auth/hooks';
import { supabase } from '@/lib/supabase/client';
import { Button } from '../components/ui/Button';
import { AlertCircle, CheckCircle, Clock } from 'lucide-react';
import toast from 'react-hot-toast';

interface StripeConnectStatus {
  stripe_account_id: string | null;
  charges_enabled: boolean;
  details_submitted: boolean;
}

export function ProducerStripeConnectPage() {
  const { user } = useAuth();
  const [status, setStatus] = useState<StripeConnectStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isFetching, setIsFetching] = useState(false);

  useEffect(() => {
    loadStatus();
  }, [user?.id]);

  const loadStatus = async () => {
    if (!user?.id) return;

    try {
      setIsLoading(true);
      const { data, error } = await supabase
        .from('user_profiles')
        .select('stripe_account_id, stripe_account_charges_enabled, stripe_account_details_submitted')
        .eq('id', user.id)
        .single();

      if (error) throw error;

      setStatus({
        stripe_account_id: data.stripe_account_id,
        charges_enabled: data.stripe_account_charges_enabled || false,
        details_submitted: data.stripe_account_details_submitted || false,
      });
    } catch (err) {
      console.error('Failed to load Stripe Connect status:', err);
      toast.error('Failed to load Stripe Connect status');
    } finally {
      setIsLoading(false);
    }
  };

  const handleStartOnboarding = async () => {
    if (!user?.id) return;

    try {
      setIsFetching(true);
      const { data: { session } } = await supabase.auth.getSession();

      if (!session) {
        toast.error('Please log in first');
        return;
      }

      const response = await fetch(
        `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/stripe-connect-onboarding`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${session.access_token}`,
          },
          body: JSON.stringify({ action: 'create_account_link' }),
        }
      );

      const result = await response.json();

      if (!response.ok) {
        throw new Error(result.error || 'Failed to create account link');
      }

      if (result.url) {
        window.location.href = result.url;
      }
    } catch (err) {
      console.error('Failed to start onboarding:', err);
      toast.error(err instanceof Error ? err.message : 'Failed to start onboarding');
    } finally {
      setIsFetching(false);
    }
  };

  const handleRefreshStatus = async () => {
    await loadStatus();
    toast.success('Status refreshed');
  };

  if (isLoading) {
    return (
      <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
        <div className="max-w-2xl mx-auto px-4">
          <div className="h-8 w-48 bg-zinc-800 rounded mb-6 animate-pulse" />
          <div className="space-y-4">
            <div className="h-32 w-full bg-zinc-800 rounded animate-pulse" />
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-2xl mx-auto px-4">
        <h1 className="text-3xl font-bold text-white mb-8">Stripe Connect Onboarding</h1>

        <div className="space-y-6">
          {/* Status Cards */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {/* Account Created */}
            <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
              <div className="flex items-start gap-3">
                {status?.stripe_account_id ? (
                  <CheckCircle className="w-5 h-5 text-emerald-400 mt-0.5" />
                ) : (
                  <Clock className="w-5 h-5 text-amber-400 mt-0.5" />
                )}
                <div>
                  <p className="text-sm font-medium text-zinc-300">Account Created</p>
                  {status?.stripe_account_id ? (
                    <p className="text-xs text-zinc-500 mt-1">
                      ID: {status.stripe_account_id.slice(0, 10)}...
                    </p>
                  ) : (
                    <p className="text-xs text-zinc-500 mt-1">Not yet created</p>
                  )}
                </div>
              </div>
            </div>

            {/* Details Submitted */}
            <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
              <div className="flex items-start gap-3">
                {status?.details_submitted ? (
                  <CheckCircle className="w-5 h-5 text-emerald-400 mt-0.5" />
                ) : (
                  <Clock className="w-5 h-5 text-amber-400 mt-0.5" />
                )}
                <div>
                  <p className="text-sm font-medium text-zinc-300">Details Submitted</p>
                  <p className="text-xs text-zinc-500 mt-1">
                    {status?.details_submitted ? 'Submitted' : 'Pending'}
                  </p>
                </div>
              </div>
            </div>

            {/* Charges Enabled */}
            <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 md:col-span-2">
              <div className="flex items-start gap-3">
                {status?.charges_enabled ? (
                  <CheckCircle className="w-5 h-5 text-emerald-400 mt-0.5" />
                ) : (
                  <AlertCircle className="w-5 h-5 text-amber-400 mt-0.5" />
                )}
                <div>
                  <p className="text-sm font-medium text-zinc-300">Ready to Accept Payments</p>
                  <p className="text-xs text-zinc-500 mt-1">
                    {status?.charges_enabled
                      ? 'Your account is ready to receive payments'
                      : 'Complete onboarding to receive payments'}
                  </p>
                </div>
              </div>
            </div>
          </div>

          {/* Actions */}
          <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-6">
            <h2 className="text-lg font-semibold text-white mb-4">Next Steps</h2>

            {!status?.stripe_account_id ? (
              <div>
                <p className="text-sm text-zinc-400 mb-4">
                  Click below to create your Stripe Connect account and start receiving payments.
                </p>
                <Button
                  onClick={handleStartOnboarding}
                  isLoading={isFetching}
                  variant="primary"
                  className="w-full md:w-auto"
                >
                  Create Stripe Connect Account
                </Button>
              </div>
            ) : !status?.details_submitted ? (
              <div>
                <p className="text-sm text-zinc-400 mb-4">
                  Click below to continue filling out your Stripe Connect details.
                </p>
                <Button
                  onClick={handleStartOnboarding}
                  isLoading={isFetching}
                  variant="primary"
                  className="w-full md:w-auto"
                >
                  Complete Onboarding
                </Button>
              </div>
            ) : !status?.charges_enabled ? (
              <div>
                <p className="text-sm text-zinc-400 mb-4">
                  Your details have been submitted. Stripe is reviewing your account.
                </p>
                <Button
                  onClick={handleRefreshStatus}
                  isLoading={isFetching}
                  variant="secondary"
                  className="w-full md:w-auto"
                >
                  Refresh Status
                </Button>
              </div>
            ) : (
              <div className="rounded-lg bg-emerald-500/10 border border-emerald-500/20 p-4">
                <p className="text-sm text-emerald-300 font-medium">
                  ✅ Your Stripe Connect account is fully set up! Payments will be transferred directly to your account.
                </p>
              </div>
            )}
          </div>

          {/* Info */}
          <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
            <h3 className="text-sm font-medium text-zinc-300 mb-2">How it works</h3>
            <ul className="text-xs text-zinc-400 space-y-2">
              <li>✓ Customers pay through our platform</li>
              <li>✓ We take a platform fee (typically 5-10%)</li>
              <li>✓ Your earnings are transferred to your Stripe account weekly</li>
              <li>✓ You can track payouts in your Stripe Dashboard</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
}
