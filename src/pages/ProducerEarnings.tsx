import { AlertCircle, CheckCircle, Clock, TrendingUp } from 'lucide-react';
import { useTranslation } from '../lib/i18n';
import { useAuth } from '../lib/auth/hooks';
import { formatDate, formatPrice } from '../lib/utils/format';
import { Badge } from '../components/ui/Badge';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '../components/ui/Card';
import { useProducerEarnings, type ProducerEarningsRow } from '../lib/producer/useProducerEarnings';

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
  const {
    data: earnings,
    loading,
    error,
    source,
  } = useProducerEarnings(profile?.id);

  const totalEarnings = earnings.reduce((sum, e) => sum + e.amount_earned_eur, 0);
  const pendingEarnings = earnings
    .filter((e) => e.payout_status === 'pending')
    .reduce((sum, e) => sum + e.amount_earned_eur, 0);
  const paidEarnings = earnings
    .filter((e) => e.payout_status === 'processed')
    .reduce((sum, e) => sum + e.amount_earned_eur, 0);

  const getPayoutStatusLabel = (row: ProducerEarningsRow): string => {
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

  const getPayoutStatusColor = (row: ProducerEarningsRow): string => {
    if (row.payout_mode !== 'platform_fallback') {
      return 'text-emerald-400 bg-emerald-400/10';
    }
    if (row.payout_status === 'processed') {
      return 'text-emerald-400 bg-emerald-400/10';
    }
    return 'text-amber-400 bg-amber-400/10';
  };

  const renderSkeleton = () => (
    <>
      <section className="grid grid-cols-1 gap-4 mb-8 sm:grid-cols-3">
        {Array.from({ length: 3 }).map((_, index) => (
          <div key={`producer-earnings-stat-${index}`} className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-4 animate-pulse">
            <div className="h-3 w-24 rounded bg-zinc-700" />
            <div className="mt-4 h-8 w-28 rounded bg-zinc-700" />
          </div>
        ))}
      </section>

      <Card>
        <CardHeader>
          <div className="h-6 w-40 rounded bg-zinc-800 animate-pulse" />
          <div className="mt-3 h-4 w-64 rounded bg-zinc-800 animate-pulse" />
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            {Array.from({ length: 5 }).map((_, index) => (
              <div key={`producer-earnings-row-${index}`} className="h-14 rounded-lg bg-zinc-800/70 animate-pulse" />
            ))}
          </div>
        </CardContent>
      </Card>
    </>
  );

  return (
    <div className="min-h-screen bg-zinc-950 py-8">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="mb-8 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <h1 className="text-3xl font-bold text-white mb-2">{t('producerEarnings.title')}</h1>
            <p className="text-zinc-400">{t('producerEarnings.subtitle')}</p>
          </div>
          {source === 'fallback' && (
            <Badge variant="warning" size="md">
              {t('producerEarnings.limitedDataMode')}
            </Badge>
          )}
        </div>

        {loading ? renderSkeleton() : (
          <>
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

            <Card className="mb-8 bg-blue-900/20 border border-blue-800/50">
              <CardContent className="pt-4">
                <p className="text-sm text-blue-300">
                  {t('producerEarnings.infoBanner')}
                </p>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>{t('producerEarnings.transactionsTitle')}</CardTitle>
                <CardDescription>{t('producerEarnings.transactionsSubtitle')}</CardDescription>
              </CardHeader>
              <CardContent>
                {error ? (
                  <div className="rounded-xl border border-red-500/20 bg-red-500/5 px-4 py-10 text-center">
                    <AlertCircle className="mx-auto mb-3 h-6 w-6 text-red-400" />
                    <p className="text-sm font-medium text-red-300">{t('producerEarnings.loadError')}</p>
                  </div>
                ) : earnings.length === 0 ? (
                  <div className="rounded-xl border border-zinc-800 bg-zinc-900/40 px-4 py-10 text-center">
                    <p className="text-sm text-zinc-400">{t('producerEarnings.noEarnings')}</p>
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
          </>
        )}
      </div>
    </div>
  );
}
