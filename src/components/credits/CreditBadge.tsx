import { Coins } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../lib/auth/hooks';
import { useCreditBalance } from '../../lib/credits/useCreditBalance';
import { useTranslation } from '../../lib/i18n';

const MAX_CREDITS = 6;

export function CreditBadge() {
  const { user } = useAuth();
  const { t } = useTranslation();
  const { balance, isLoading } = useCreditBalance(user?.id);
  const safeBalance = typeof balance === 'number' ? Math.max(0, Math.min(balance, MAX_CREDITS)) : 0;
  const isMaxReached = safeBalance >= MAX_CREDITS;

  if (!user || isLoading) {
    return null;
  }

  return (
    <Link
      to="/dashboard"
      className={`inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-sm font-medium transition-all ${
        isMaxReached
          ? 'border border-amber-400/40 bg-gradient-to-r from-amber-500/20 to-rose-500/20 text-amber-50 shadow-lg shadow-amber-500/10 hover:border-amber-300/60'
          : 'border border-emerald-500/30 bg-emerald-500/10 text-emerald-100 hover:border-emerald-400/50 hover:bg-emerald-500/15'
      }`}
      title={`${t('dashboard.creditsMonthlyHint')}${isMaxReached ? ` • ${t('dashboard.creditsCapReached')}` : ''}`}
    >
      <Coins className={`h-4 w-4 ${isMaxReached ? 'text-amber-200' : 'text-emerald-300'}`} />
      <span>{`🎧 ${t('dashboard.creditsProgressLabel', { count: safeBalance, max: MAX_CREDITS })}`}</span>
    </Link>
  );
}
