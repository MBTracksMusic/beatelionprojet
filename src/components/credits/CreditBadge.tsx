import { Coins } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useAuth } from '../../lib/auth/hooks';
import { useCreditBalance } from '../../lib/credits/useCreditBalance';
import { useTranslation } from '../../lib/i18n';

export function CreditBadge() {
  const { user } = useAuth();
  const { t } = useTranslation();
  const { balance, isLoading } = useCreditBalance(user?.id);

  if (!user || isLoading) {
    return null;
  }

  return (
    <Link
      to="/dashboard"
      className="inline-flex items-center gap-2 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-3 py-1.5 text-sm font-medium text-emerald-100 transition-colors hover:border-emerald-400/50 hover:bg-emerald-500/15"
      title={t('pricing.userPremiumTitle')}
    >
      <Coins className="h-4 w-4 text-emerald-300" />
      <span>{balance ?? 0}</span>
    </Link>
  );
}
