import { useEffect, useRef, useState } from 'react';
import { RefreshCw, UserPlus, Users } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button } from '../ui/Button';
import { Card, CardContent, CardHeader, CardTitle } from '../ui/Card';
import { Input } from '../ui/Input';
import { invokeProtectedEdgeFunction } from '../../lib/supabase/edgeAuth';

// ─── Types ───────────────────────────────────────────────────────────────────

interface CampaignProducer {
  user_id: string;
  username: string | null;
  full_name: string | null;
  email: string | null;
  founding_trial_start: string | null;
  founding_trial_end: string | null;
  founding_trial_active: boolean;
  founding_trial_expired: boolean;
  days_remaining: number;
  slot_number: number;
}

interface CampaignInfo {
  type: string;
  label: string;
  max_slots: number | null;
  is_active: boolean;
  trial_duration: string | null;
  slots_used: number;
  slots_remaining: number | null;
}

interface GetCampaignResponse {
  campaign: CampaignInfo;
  producers: CampaignProducer[];
}

interface AssignCampaignResponse {
  ok: boolean;
  result: {
    user_id: string;
    campaign_type: string;
    trial_start: string;
    trial_end: string;
    slots_used: number;
    slots_max: number | null;
  };
  resolved_user?: {
    id: string;
    username: string | null;
    email: string | null;
  };
}

interface UnassignCampaignResponse {
  ok: boolean;
  result: {
    success: boolean;
    user_id: string;
    message: string;
  };
  resolved_user?: {
    id: string;
    username: string | null;
    email: string | null;
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/i;

const formatDate = (value: string | null) => {
  if (!value) return '—';
  try {
    return new Intl.DateTimeFormat('fr-FR', { dateStyle: 'medium' }).format(new Date(value));
  } catch {
    return value;
  }
};

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const parseErrorMessage = (error: unknown): string => {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  return 'Une erreur inattendue est survenue.';
};

const getAssignErrorMessage = (error: unknown) => {
  const message = parseErrorMessage(error);
  const normalized = message.toLowerCase();

  if (normalized.includes('user_not_found') || normalized.includes('user not found')) {
    return 'Utilisateur introuvable.';
  }

  if (normalized.includes('campaign_full') || normalized.includes('is full')) {
    return 'La campagne est complète.';
  }

  return message;
};

const getRemoveErrorMessage = (error: unknown) => {
  const message = parseErrorMessage(error);
  const normalized = message.toLowerCase();

  if (normalized.includes('user_not_found') || normalized.includes('user not found')) {
    return 'Utilisateur introuvable.';
  }

  return message;
};

// ─── Component ───────────────────────────────────────────────────────────────

interface ProducerCampaignManagerProps {
  campaignType?: string;
}

export function ProducerCampaignManager({ campaignType = 'founding' }: ProducerCampaignManagerProps) {
  const [campaign, setCampaign] = useState<CampaignInfo | null>(null);
  const [producers, setProducers] = useState<CampaignProducer[]>([]);
  const [isLoadingList, setIsLoadingList] = useState(false);
  const [listError, setListError] = useState<string | null>(null);

  const [producerIdentifierInput, setProducerIdentifierInput] = useState('');
  const [isAssigning, setIsAssigning] = useState(false);
  const [removingUserId, setRemovingUserId] = useState<string | null>(null);

  const isMountedRef = useRef(true);
  useEffect(() => {
    isMountedRef.current = true;
    return () => { isMountedRef.current = false; };
  }, []);

  const loadCampaign = async () => {
    setIsLoadingList(true);
    setListError(null);

    try {
      const data = await invokeProtectedEdgeFunction<GetCampaignResponse>('admin-get-campaign', {
        body: { campaign_type: campaignType },
      });

      if (!isMountedRef.current) return;
      setCampaign(data?.campaign ?? null);
      setProducers(data?.producers ?? []);
    } catch (err) {
      if (!isMountedRef.current) return;
      setListError(parseErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsLoadingList(false);
      }
    }
  };

  useEffect(() => {
    void loadCampaign();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [campaignType]);

  const handleAssign = async () => {
    const producerIdentifier = asNonEmptyString(producerIdentifierInput);

    if (!producerIdentifier) {
      toast.error('Veuillez saisir un email valide.');
      return;
    }

    const isUuidInput = UUID_RE.test(producerIdentifier);
    const normalizedEmail = producerIdentifier.toLowerCase();

    if (!isUuidInput && !EMAIL_RE.test(normalizedEmail)) {
      toast.error('Veuillez saisir un email valide.');
      return;
    }

    setIsAssigning(true);

    try {
      const payload = isUuidInput
        ? { user_id: producerIdentifier, campaign_type: campaignType }
        : { email: normalizedEmail, campaign_type: campaignType };

      const data = await invokeProtectedEdgeFunction<AssignCampaignResponse>('admin-assign-campaign', {
        body: payload,
      });

      if (!isMountedRef.current) return;

      const slotsUsed = data?.result?.slots_used ?? '?';
      const slotsMax = data?.result?.slots_max != null ? data.result.slots_max : '∞';
      const resolvedIdentity = data?.resolved_user?.email ?? data?.resolved_user?.username ?? producerIdentifier;
      toast.success(`Producteur activé (${resolvedIdentity}). Slots : ${slotsUsed} / ${slotsMax}`);
      setProducerIdentifierInput('');
      await loadCampaign();
    } catch (err) {
      if (!isMountedRef.current) return;
      toast.error(getAssignErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsAssigning(false);
      }
    }
  };

  const handleRemove = async (producer: CampaignProducer) => {
    const producerIdentity =
      producer.username
      ?? producer.full_name
      ?? producer.email
      ?? producer.user_id;

    const confirmed = window.confirm('Confirmer la suppression de ce producteur ?');
    if (!confirmed) {
      return;
    }

    setRemovingUserId(producer.user_id);

    try {
      const data = await invokeProtectedEdgeFunction<UnassignCampaignResponse>('admin-unassign-campaign', {
        body: { user_id: producer.user_id },
      });

      if (!isMountedRef.current) return;

      const resolvedIdentity = data?.resolved_user?.email ?? data?.resolved_user?.username ?? producerIdentity;
      toast.success(`Producteur retiré (${resolvedIdentity}).`);
      await loadCampaign();
    } catch (err) {
      if (!isMountedRef.current) return;
      toast.error(getRemoveErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setRemovingUserId(null);
      }
    }
  };

  // ── Slots bar ──
  const slotsPercent =
    campaign?.max_slots != null && campaign.max_slots > 0
      ? Math.min(100, Math.round((campaign.slots_used / campaign.max_slots) * 100))
      : null;

  const slotsLabel = campaign
    ? campaign.max_slots != null
      ? `${campaign.slots_used} / ${campaign.max_slots} slots utilisés`
      : `${campaign.slots_used} producteur${campaign.slots_used > 1 ? 's' : ''} (illimité)`
    : null;

  const slotsRemainingLabel =
    campaign?.max_slots != null && campaign.slots_remaining != null
      ? `${campaign.slots_remaining} slot${campaign.slots_remaining > 1 ? 's' : ''} restant${campaign.slots_remaining > 1 ? 's' : ''}`
      : null;

  return (
    <Card className="md:col-span-2 border-zinc-800">
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center gap-2 text-base font-semibold text-white">
          <Users className="h-5 w-5 text-rose-400" />
          Campagne Producteurs — {campaign?.label ?? campaignType}
        </CardTitle>
      </CardHeader>

      <CardContent className="flex flex-col gap-5 p-5 pt-0">

        {/* Slots counter */}
        {campaign && (
          <div className="flex flex-col gap-1">
            <div className="flex items-center justify-between text-sm">
              <div className="flex flex-col">
                <span className="text-zinc-400">{slotsLabel}</span>
                {slotsRemainingLabel && (
                  <span className="text-xs text-zinc-500">{slotsRemainingLabel}</span>
                )}
              </div>
              {campaign.max_slots != null && slotsPercent !== null && (
                <span className={`font-medium ${slotsPercent >= 100 ? 'text-red-400' : slotsPercent >= 80 ? 'text-orange-400' : 'text-emerald-400'}`}>
                  {slotsPercent}%
                </span>
              )}
            </div>
            {campaign.max_slots != null && slotsPercent !== null && (
              <div className="h-1.5 w-full overflow-hidden rounded-full bg-zinc-800">
                <div
                  className={`h-full rounded-full transition-all ${
                    slotsPercent >= 100 ? 'bg-red-500' : slotsPercent >= 80 ? 'bg-orange-500' : 'bg-emerald-500'
                  }`}
                  style={{ width: `${slotsPercent}%` }}
                />
              </div>
            )}
          </div>
        )}

        {/* Assign form */}
        <div className="flex flex-col gap-3 rounded-lg border border-zinc-800 bg-zinc-950/60 p-4 sm:flex-row sm:items-end">
          <div className="flex-1">
            <label className="mb-1.5 block text-xs font-medium text-zinc-400">
              Email du producteur
            </label>
            <Input
              value={producerIdentifierInput}
              onChange={(e) => setProducerIdentifierInput(e.target.value)}
              placeholder="producteur@beatelion.com"
              disabled={isAssigning}
              className="text-sm"
            />
          </div>
          <Button
            onClick={handleAssign}
            disabled={isAssigning || !producerIdentifierInput.trim()}
            className="flex shrink-0 items-center gap-2 whitespace-nowrap"
          >
            <UserPlus className="h-4 w-4" />
            {isAssigning ? 'Activation…' : 'Activer Founding'}
          </Button>
        </div>

        {/* Participants list */}
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium text-zinc-300">
              Participants ({producers.length})
            </p>
            <button
              type="button"
              onClick={() => { void loadCampaign(); }}
              disabled={isLoadingList}
              className="flex items-center gap-1.5 rounded-md border border-zinc-800 bg-zinc-950/60 px-3 py-1.5 text-xs text-zinc-400 transition-colors hover:border-zinc-700 hover:text-white disabled:opacity-50"
            >
              <RefreshCw className={`h-3 w-3 ${isLoadingList ? 'animate-spin' : ''}`} />
              Actualiser
            </button>
          </div>

          {listError && (
            <p className="rounded-md border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-400">
              {listError}
            </p>
          )}

          {!listError && !isLoadingList && producers.length === 0 && (
            <p className="rounded-md border border-zinc-800 p-4 text-center text-sm text-zinc-500">
              Aucun producteur dans cette campagne.
            </p>
          )}

          {producers.length > 0 && (
            <div className="overflow-x-auto rounded-lg border border-zinc-800">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-zinc-800 bg-zinc-950/60">
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-500">Slot</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-500">Producteur</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-500">Début trial</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-500">Fin trial</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-500">Statut</th>
                    <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-zinc-500">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-800">
                  {producers.map((p) => (
                    <tr key={p.user_id} className="hover:bg-zinc-900/40">
                      <td className="px-4 py-3 text-zinc-400">
                        #{p.slot_number}
                      </td>
                      <td className="px-4 py-3">
                        <div className="font-medium text-white">
                          {p.username ?? p.full_name ?? p.email ?? '—'}
                        </div>
                        <div className="text-xs text-zinc-400">
                          {p.email ?? '—'}
                        </div>
                        <div className="font-mono text-xs text-zinc-600 truncate max-w-[180px]">
                          {p.user_id}
                        </div>
                      </td>
                      <td className="px-4 py-3 text-zinc-400">
                        {formatDate(p.founding_trial_start)}
                      </td>
                      <td className="px-4 py-3 text-zinc-400">
                        {formatDate(p.founding_trial_end)}
                      </td>
                      <td className="px-4 py-3">
                        {p.founding_trial_active ? (
                          <div className="inline-flex items-center gap-1 rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2.5 py-0.5 text-xs font-medium text-emerald-400">
                            <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
                            Actif - {p.days_remaining} jour{p.days_remaining > 1 ? 's' : ''} restant{p.days_remaining > 1 ? 's' : ''}
                          </div>
                        ) : (
                          <div className="inline-flex items-center gap-1 rounded-full border border-red-500/20 bg-red-500/10 px-2.5 py-0.5 text-xs font-medium text-red-400">
                            <span className="h-1.5 w-1.5 rounded-full bg-red-400" />
                            {p.founding_trial_expired ? 'Expiré' : 'Inactif'}
                          </div>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right">
                        <Button
                          type="button"
                          variant="danger"
                          size="sm"
                          onClick={() => { void handleRemove(p); }}
                          disabled={removingUserId !== null}
                          isLoading={removingUserId === p.user_id}
                        >
                          Retirer
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
