import { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Input } from '../../components/ui/Input';
import { Button } from '../../components/ui/Button';
import { Card } from '../../components/ui/Card';
import { ReputationBadge } from '../../components/reputation/ReputationBadge';
import { supabase } from '../../lib/supabase/client';
import type { ReputationRankTier } from '../../lib/supabase/types';

interface AdminReputationRow {
  user_id: string;
  username: string | null;
  email: string | null;
  role: string;
  avatar_url: string | null;
  producer_tier: string | null;
  xp: number;
  level: number;
  rank_tier: ReputationRankTier;
  forum_xp: number;
  battle_xp: number;
  commerce_xp: number;
  reputation_score: number;
  updated_at: string;
}

export function AdminReputationPage() {
  const [rows, setRows] = useState<AdminReputationRow[]>([]);
  const [search, setSearch] = useState('');
  const [selectedUser, setSelectedUser] = useState<AdminReputationRow | null>(null);
  const [delta, setDelta] = useState('');
  const [reason, setReason] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const loadRows = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabase.rpc('rpc_admin_get_reputation_overview' as any, {
      p_search: search.trim() || null,
      p_limit: 80,
    });

    if (error) {
      console.error('Error loading reputation overview:', error);
      toast.error('Impossible de charger la réputation.');
      setRows([]);
      setIsLoading(false);
      return;
    }

    setRows((data as AdminReputationRow[] | null) ?? []);
    setIsLoading(false);
  }, [search]);

  useEffect(() => {
    void loadRows();
  }, [loadRows]);

  const submitAdjustment = async () => {
    if (!selectedUser) {
      toast.error('Sélectionnez un utilisateur.');
      return;
    }

    const parsedDelta = Number.parseInt(delta, 10);
    if (!Number.isFinite(parsedDelta) || parsedDelta === 0) {
      toast.error('Delta XP invalide.');
      return;
    }

    if (!reason.trim()) {
      toast.error('Le motif est requis.');
      return;
    }

    setIsSubmitting(true);
    const { error } = await supabase.rpc('admin_adjust_reputation' as any, {
      p_user_id: selectedUser.user_id,
      p_delta_xp: parsedDelta,
      p_reason: reason.trim(),
      p_metadata: {
        ui: 'admin_reputation_page',
      },
    });

    if (error) {
      console.error('Error adjusting reputation:', error);
      toast.error('Ajustement impossible.');
      setIsSubmitting(false);
      return;
    }

    toast.success('Réputation ajustée.');
    setDelta('');
    setReason('');
    await loadRows();
    setIsSubmitting(false);
  };

  return (
    <div className="space-y-4">
      <Card className="p-5">
        <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <h2 className="text-xl font-semibold text-white">Réputation</h2>
            <p className="text-sm text-zinc-400">Vue admin et overrides audités.</p>
          </div>
          <Button variant="outline" onClick={() => void loadRows()}>
            Actualiser
          </Button>
        </div>
      </Card>

      <Card className="p-5 space-y-4">
        <Input
          label="Recherche"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="username ou email"
        />
        <div className="grid gap-4 md:grid-cols-3">
          <Input
            label="Utilisateur ciblé"
            value={selectedUser ? `${selectedUser.username || selectedUser.email || selectedUser.user_id}` : ''}
            readOnly
            placeholder="Choisir dans la liste"
          />
          <Input
            label="Delta XP"
            value={delta}
            onChange={(event) => setDelta(event.target.value)}
            placeholder="+25 ou -10"
          />
          <Input
            label="Motif"
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Ajustement admin"
          />
        </div>
        <div className="flex gap-3">
          <Button onClick={() => void submitAdjustment()} isLoading={isSubmitting}>
            Appliquer
          </Button>
          <Button
            variant="outline"
            onClick={() => {
              setSelectedUser(null);
              setDelta('');
              setReason('');
            }}
          >
            Réinitialiser
          </Button>
        </div>
      </Card>

      <Card className="p-5">
        {isLoading ? (
          <p className="text-zinc-400">Chargement...</p>
        ) : rows.length === 0 ? (
          <p className="text-zinc-500">Aucun profil trouvé.</p>
        ) : (
          <div className="space-y-3">
            {rows.map((row) => (
              <div key={row.user_id} className="rounded-lg border border-zinc-800 bg-zinc-950/50 p-4">
                <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <p className="font-medium text-white">{row.username || row.email || row.user_id}</p>
                      <span className="text-xs text-zinc-500">{row.role}</span>
                    </div>
                    <p className="text-sm text-zinc-500">{row.email || 'email indisponible'}</p>
                    <ReputationBadge rankTier={row.rank_tier} level={row.level} xp={row.xp} />
                    <p className="text-xs text-zinc-500">
                      Forum {row.forum_xp} • Battles {row.battle_xp} • Commerce {row.commerce_xp}
                    </p>
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="text-right text-sm text-zinc-400">
                      <div className="text-white font-semibold">{row.xp} XP</div>
                      <div>Maj {new Date(row.updated_at).toLocaleString('fr-FR')}</div>
                    </div>
                    <Button variant="outline" onClick={() => setSelectedUser(row)}>
                      Ajuster
                    </Button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
