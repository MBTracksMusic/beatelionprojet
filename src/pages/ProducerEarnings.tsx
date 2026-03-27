import { useEffect, useState } from 'react';
import { TrendingUp, Clock, CheckCircle } from 'lucide-react';
import { useTranslation } from '../lib/i18n';
import { useAuth } from '../lib/auth/hooks';
import { supabase } from '@/lib/supabase/client';
import { formatDate, formatPrice } from '../lib/utils/format';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../components/ui/Card';

interface RevenueRow {
  id: string;
  created_at: string;
  product_id: string;
  product_title: string;
  purchase_source: string | null;
  amount_earned_eur: number;
  payout_status: string;
  payout_mode: string;
  payout_processed_at: string | null;
}

function StatCard({
  icon: Icon,
  label,
  value,
}: {
  icon: React.ComponentType<{ className: string }>;
  label: string;
  value: string | number;
}) {
  return (
    <div className="bg-zinc-800/50 border border-zinc-700 rounded-lg p-4">
      <div className="flex items-start justify-between">
        <div className="flex-1">
          <p className="text-xs text-zinc-400 uppercase tracking-wide mb-1">{label}</p>
          <p className="text-2xl font-bold text-white">{value}</p>
        </div>
        <Icon className="h-5 w-5 text-zinc-500" />
      </div>
    </div>
  );
}

export function ProducerEarnings() {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const [earnings, setEarnings] = useState<RevenueRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let isCancelled = false;

    async function loadEarnings() {
      if (!profile?.id) {
        if (!isCancelled) {
          setEarnings([]);
          setIsLoading(false);
        }
        return;
      }

      setIsLoading(true);
      setError(null);

      try {
        const { data, error: fetchError } = await supabase
          .from('producer_revenue_view')
          .select('*');

        if (fetchError) throw fetchError;

        if (!isCancelled) {
          setEarnings((data as RevenueRow[]) || []);
        }
      } catch (err) {
        console.error('Error loading earnings:', err);
        if (!isCancelled) {
          setError(t('producerEarnings.loadError'));
        }
      } finally {
        if (!isCancelled) {
          setIsLoading(false);
        }
      }
    }

    void loadEarnings();

    return () => {
      isCancelled = true;
    };
  }, [profile?.id, t]);

  const totalEarnings = earnings.reduce((sum, e) => sum + e.amount_earned_eur, 0);
  const pendingEarnings = earnings
    .filter((e) => e.payout_status === 'pending')
    .reduce((sum, e) => sum + e.amount_earned_eur, 0);
  const paidEarnings = earnings
    .filter((e) => e.payout_status === 'processed')
    .reduce((sum, e) => sum + e.amount_earned_eur, 0);

  const getPayoutStatusLabel = (row: RevenueRow): string => {
    if (row.payout_mode !== 'platform_fallback') {
      return t('producerEarnings.paidAutomatically');
    }
    if (row.payout_status === 'pending') {
      return t('producerEarnings.pendingPayout');
    }
    if (row.payout_status === 'processed') {
      return t('producerEarnings.paid');
    }
    return row.payout_status;
  };

  const getPayoutStatusColor = (row: RevenueRow): string => {
    if (row.payout_mode !== 'platform_fallback') {
      return 'text-emerald-400 bg-emerald-400/10';
    }
    if (row.payout_status === 'processed') {
      return 'text-emerald-400 bg-emerald-400/10';
    }
    return 'text-amber-400 bg-amber-400/10';
  };

  return (
    <div className="min-h-screen bg-zinc-950 py-8">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">{t('producerEarnings.title')}</h1>
          <p className="text-zinc-400">{t('producerEarnings.subtitle')}</p>
        </div>

        {/* Summary Cards */}
        <section className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
          <StatCard
            icon={TrendingUp}
            label={t('producerEarnings.totalEarnings')}
            value={formatPrice(Math.round(totalEarnings * 100))}
          />
          <StatCard
            icon={Clock}
            label={t('producerEarnings.pendingPayouts')}
            value={formatPrice(Math.round(pendingEarnings * 100))}
          />
          <StatCard
            icon={CheckCircle}
            label={t('producerEarnings.paidPayouts')}
            value={formatPrice(Math.round(paidEarnings * 100))}
          />
        </section>

        {/* Info Banner */}
        <Card className="mb-8 bg-blue-900/20 border border-blue-800/50">
          <CardContent className="pt-4">
            <p className="text-sm text-blue-300">
              {t('producerEarnings.infoBanner')}
            </p>
          </CardContent>
        </Card>

        {/* Earnings Table */}
        <Card>
          <CardHeader>
            <CardTitle>{t('producerEarnings.transactionsTitle')}</CardTitle>
            <CardDescription>{t('producerEarnings.transactionsSubtitle')}</CardDescription>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="text-center py-8">
                <p className="text-zinc-400">{t('common.loading')}</p>
              </div>
            ) : error ? (
              <div className="text-center py-8">
                <p className="text-red-400">{error}</p>
              </div>
            ) : earnings.length === 0 ? (
              <div className="text-center py-8">
                <p className="text-zinc-400">{t('producerEarnings.noEarnings')}</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-zinc-800">
                      <th className="text-left py-3 px-4 text-xs font-semibold text-zinc-400 uppercase tracking-wide">
                        {t('common.date')}
                      </th>
                      <th className="text-left py-3 px-4 text-xs font-semibold text-zinc-400 uppercase tracking-wide">
                        {t('common.product')}
                      </th>
                      <th className="text-left py-3 px-4 text-xs font-semibold text-zinc-400 uppercase tracking-wide">
                        {t('common.type')}
                      </th>
                      <th className="text-right py-3 px-4 text-xs font-semibold text-zinc-400 uppercase tracking-wide">
                        {t('common.amount')}
                      </th>
                      <th className="text-right py-3 px-4 text-xs font-semibold text-zinc-400 uppercase tracking-wide">
                        {t('common.status')}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {earnings.map((row) => (
                      <tr key={row.id} className="border-b border-zinc-800/50 hover:bg-zinc-800/30 transition">
                        <td className="py-3 px-4 text-zinc-300">{formatDate(new Date(row.created_at))}</td>
                        <td className="py-3 px-4 text-zinc-300">{row.product_title}</td>
                        <td className="py-3 px-4 text-zinc-300">
                          {row.purchase_source === 'credits' ? t('common.credits') : t('common.cash')}
                        </td>
                        <td className="py-3 px-4 text-right text-white font-semibold">
                          {formatPrice(Math.round(row.amount_earned_eur * 100))}
                        </td>
                        <td className="py-3 px-4 text-right">
                          <span className={`text-xs font-semibold px-2.5 py-1 rounded-full ${getPayoutStatusColor(row)}`}>
                            {getPayoutStatusLabel(row)}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
