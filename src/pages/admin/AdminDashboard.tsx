import { useState } from 'react';
import { ArrowRight, BarChart3, Inbox, Newspaper, Settings2, Swords } from 'lucide-react';
import toast from 'react-hot-toast';
import { Link } from 'react-router-dom';
import { Button } from '../../components/ui/Button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card';
import { useTranslation } from '../../lib/i18n';
import { useMaintenanceModeContext } from '../../lib/supabase/MaintenanceModeContext';

export function AdminDashboardPage() {
  const { t } = useTranslation();
  const { maintenance, updatedAt, isLoading, updateMaintenanceMode } = useMaintenanceModeContext();
  const [isSavingMaintenance, setIsSavingMaintenance] = useState(false);

  const handleMaintenanceToggle = async () => {
    setIsSavingMaintenance(true);

    try {
      const nextValue = !maintenance;
      await updateMaintenanceMode(nextValue);
      toast.success(nextValue ? 'Mode maintenance activé.' : 'Mode maintenance désactivé.');
    } catch {
      toast.error("Impossible de mettre à jour le mode maintenance.");
    } finally {
      setIsSavingMaintenance(false);
    }
  };

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
      <Card className="md:col-span-2 border-zinc-800">
        <CardHeader className="mb-0">
          <div className="flex items-start justify-between gap-4">
            <div>
              <CardTitle className="flex items-center gap-2">
                <Settings2 className="w-5 h-5 text-rose-400" />
                Maintenance globale
              </CardTitle>
              <CardDescription className="mt-2">
                Active ou désactive le blocage global du site en temps réel, sans redéploiement.
              </CardDescription>
            </div>
            <div className="inline-flex items-center rounded-full border border-zinc-700 bg-zinc-900 px-3 py-1 text-xs font-medium text-zinc-300">
              {isLoading ? 'Chargement...' : maintenance ? 'ON' : 'OFF'}
            </div>
          </div>
        </CardHeader>

        <CardContent className="flex flex-col gap-4 pt-4">
          <label className="flex items-center justify-between gap-4 rounded-xl border border-zinc-800 bg-zinc-950/60 px-4 py-3">
            <div className="min-w-0">
              <p className="text-sm font-medium text-white">Mode maintenance</p>
              <p className="text-sm text-zinc-400">
                {maintenance
                  ? 'Le site public est actuellement bloqué pour les visiteurs.'
                  : 'Le site public est actuellement accessible.'}
              </p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={maintenance}
              aria-label="Basculer le mode maintenance"
              onClick={handleMaintenanceToggle}
              disabled={isLoading || isSavingMaintenance}
              className={`relative inline-flex h-7 w-12 items-center rounded-full border transition-colors ${
                maintenance
                  ? 'border-rose-500 bg-rose-500/90'
                  : 'border-zinc-700 bg-zinc-800'
              } disabled:cursor-not-allowed disabled:opacity-60`}
            >
              <span
                className={`inline-block h-5 w-5 transform rounded-full bg-white transition-transform ${
                  maintenance ? 'translate-x-6' : 'translate-x-1'
                }`}
              />
            </button>
          </label>

          <div className="flex flex-wrap items-center justify-between gap-3 text-sm text-zinc-400">
            <span>
              Dernière mise à jour : {updatedAt ? new Date(updatedAt).toLocaleString() : 'inconnue'}
            </span>
            <Button
              variant={maintenance ? 'secondary' : 'primary'}
              onClick={handleMaintenanceToggle}
              isLoading={isSavingMaintenance}
              disabled={isLoading}
            >
              {maintenance ? 'Désactiver la maintenance' : 'Activer la maintenance'}
            </Button>
          </div>
        </CardContent>
      </Card>

      <Link to="/admin/news" className="group">
        <Card className="h-full border-zinc-800 hover:border-rose-500/60 transition-colors">
          <CardContent className="p-5">
            <div className="flex items-start justify-between gap-3">
              <div>
                <CardTitle className="flex items-center gap-2">
                  <Newspaper className="w-5 h-5 text-rose-400" />
                  {t('admin.dashboard.newsTitle')}
                </CardTitle>
                <CardDescription className="mt-2">
                  {t('admin.dashboard.newsDescription')}
                </CardDescription>
              </div>
              <ArrowRight className="w-4 h-4 text-zinc-500 group-hover:text-white transition-colors" />
            </div>
          </CardContent>
        </Card>
      </Link>

      <Link to="/admin/battles" className="group">
        <Card className="h-full border-zinc-800 hover:border-rose-500/60 transition-colors">
          <CardContent className="p-5">
            <div className="flex items-start justify-between gap-3">
              <div>
                <CardTitle className="flex items-center gap-2">
                  <Swords className="w-5 h-5 text-rose-400" />
                  {t('admin.dashboard.battlesTitle')}
                </CardTitle>
                <CardDescription className="mt-2">
                  {t('admin.dashboard.battlesDescription')}
                </CardDescription>
              </div>
              <ArrowRight className="w-4 h-4 text-zinc-500 group-hover:text-white transition-colors" />
            </div>
          </CardContent>
        </Card>
      </Link>

      <Link to="/admin/messages" className="group">
        <Card className="h-full border-zinc-800 hover:border-rose-500/60 transition-colors">
          <CardContent className="p-5">
            <div className="flex items-start justify-between gap-3">
              <div>
                <CardTitle className="flex items-center gap-2">
                  <Inbox className="w-5 h-5 text-rose-400" />
                  {t('admin.dashboard.messagesTitle')}
                </CardTitle>
                <CardDescription className="mt-2">
                  {t('admin.dashboard.messagesDescription')}
                </CardDescription>
              </div>
              <ArrowRight className="w-4 h-4 text-zinc-500 group-hover:text-white transition-colors" />
            </div>
          </CardContent>
        </Card>
      </Link>

      <Link to="/admin/beat-analytics" className="group">
        <Card className="h-full border-zinc-800 hover:border-rose-500/60 transition-colors">
          <CardContent className="p-5">
            <div className="flex items-start justify-between gap-3">
              <div>
                <CardTitle className="flex items-center gap-2">
                  <BarChart3 className="w-5 h-5 text-rose-400" />
                  {t('admin.dashboard.beatAnalyticsTitle')}
                </CardTitle>
                <CardDescription className="mt-2">
                  {t('admin.dashboard.beatAnalyticsDescription')}
                </CardDescription>
              </div>
              <ArrowRight className="w-4 h-4 text-zinc-500 group-hover:text-white transition-colors" />
            </div>
          </CardContent>
        </Card>
      </Link>
    </div>
  );
}
