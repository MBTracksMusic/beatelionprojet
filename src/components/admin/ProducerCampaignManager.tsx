import { useEffect, useRef, useState } from 'react';
import { RefreshCw, RotateCcw, Save, ShieldCheck, UserPlus, Users } from 'lucide-react';
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
    producer_access_revoked?: boolean;
    has_active_subscription?: boolean;
  };
  resolved_user?: {
    id: string;
    username: string | null;
    email: string | null;
  };
}

interface ResetCampaignTrialResponse {
  ok: boolean;
  result: {
    success: boolean;
    user_id: string;
    campaign_type: string;
    trial_start: string;
    trial_end: string;
    days_remaining: number;
  };
}

interface ToggleCampaignResponse {
  ok: boolean;
  campaign: Pick<CampaignInfo, 'type' | 'label' | 'max_slots' | 'is_active' | 'trial_duration'>;
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

  if (normalized.includes('campaign_inactive') || normalized.includes('not active')) {
    return 'La campagne serveur est fermée. Ouvre-la avant d’activer un producteur.';
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

const getResetErrorMessage = (error: unknown) => {
  const message = parseErrorMessage(error);
  const normalized = message.toLowerCase();

  if (normalized.includes('campaign_membership_mismatch') || normalized.includes('not assigned to campaign')) {
    return 'Ce producteur n’est plus assigné à cette campagne.';
  }

  if (normalized.includes('user_not_found') || normalized.includes('user not found')) {
    return 'Utilisateur introuvable.';
  }

  return message;
};

const getSlotsErrorMessage = (error: unknown) => {
  const message = parseErrorMessage(error);
  const normalized = message.toLowerCase();

  if (normalized.includes('campaign_slots_below_used') || normalized.includes('greater than or equal')) {
    return 'Impossible de définir moins de slots que le nombre de participants déjà assignés.';
  }

  if (normalized.includes('invalid max_slots')) {
    return 'Le nombre de slots doit être un entier positif.';
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
  const [maxSlotsInput, setMaxSlotsInput] = useState('');
  const [isAssigning, setIsAssigning] = useState(false);
  const [isTogglingCampaign, setIsTogglingCampaign] = useState(false);
  const [isUpdatingMaxSlots, setIsUpdatingMaxSlots] = useState(false);
  const [removingUserId, setRemovingUserId] = useState<string | null>(null);
  const [resettingUserId, setResettingUserId] = useState<string | null>(null);

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
      const nextCampaign = data?.campaign ?? null;
      setCampaign(nextCampaign);
      setMaxSlotsInput(nextCampaign?.max_slots != null ? String(nextCampaign.max_slots) : '');
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

  const handleToggleCampaignActive = async () => {
    if (!campaign || isTogglingCampaign) return;

    const nextIsActive = !campaign.is_active;
    const confirmed = nextIsActive
      ? true
      : window.confirm(
          'Fermer la campagne serveur ? Les nouvelles demandes founding seront bloquées, mais les waitlists et trials existants ne seront pas modifiés.',
        );

    if (!confirmed) return;

    setIsTogglingCampaign(true);

    try {
      const data = await invokeProtectedEdgeFunction<ToggleCampaignResponse>('admin-toggle-campaign', {
        body: {
          campaign_type: campaign.type,
          is_active: nextIsActive,
        },
      });

      const nextCampaign = data?.campaign;
      if (!nextCampaign) {
        throw new Error('Réponse campagne invalide.');
      }

      if (!isMountedRef.current) return;
      setCampaign((current) => current ? { ...current, ...nextCampaign } : null);
      toast.success(nextIsActive ? 'Campagne serveur ouverte.' : 'Campagne serveur fermée.');
    } catch (err) {
      if (!isMountedRef.current) return;
      toast.error(parseErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsTogglingCampaign(false);
      }
    }
  };

  const handleUpdateMaxSlots = async () => {
    if (!campaign || isUpdatingMaxSlots) return;

    const rawValue = maxSlotsInput.trim();
    const nextMaxSlots = rawValue.length === 0 ? null : Number(rawValue);

    if (
      nextMaxSlots !== null
      && (!Number.isInteger(nextMaxSlots) || nextMaxSlots <= 0)
    ) {
      toast.error('Le nombre de slots doit être un entier positif.');
      return;
    }

    if (nextMaxSlots !== null && nextMaxSlots < campaign.slots_used) {
      toast.error(`Impossible de descendre sous ${campaign.slots_used} slots déjà utilisés.`);
      return;
    }

    if (nextMaxSlots === campaign.max_slots) {
      return;
    }

    setIsUpdatingMaxSlots(true);

    try {
      await invokeProtectedEdgeFunction<ToggleCampaignResponse>('admin-toggle-campaign', {
        body: {
          campaign_type: campaign.type,
          is_active: campaign.is_active,
          max_slots: nextMaxSlots,
        },
      });

      if (!isMountedRef.current) return;
      toast.success(nextMaxSlots === null ? 'Slots passés en illimité.' : `Slots max mis à jour : ${nextMaxSlots}.`);
      await loadCampaign();
    } catch (err) {
      if (!isMountedRef.current) return;
      toast.error(getSlotsErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setIsUpdatingMaxSlots(false);
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
      const accessDetail = data?.result?.producer_access_revoked === false
        ? 'Accès payé conservé.'
        : 'Accès producteur révoqué.';
      toast.success(`Producteur retiré de la campagne (${resolvedIdentity}). ${accessDetail}`);
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

  const handleResetTrial = async (producer: CampaignProducer) => {
    const producerIdentity =
      producer.username
      ?? producer.full_name
      ?? producer.email
      ?? producer.user_id;

    const confirmed = window.confirm(
      `Réinitialiser le trial de ${producerIdentity} ? La nouvelle fin sera recalculée à partir d'aujourd'hui.`,
    );
    if (!confirmed) {
      return;
    }

    setResettingUserId(producer.user_id);

    try {
      const data = await invokeProtectedEdgeFunction<ResetCampaignTrialResponse>('admin-reset-campaign-trial', {
        body: {
          user_id: producer.user_id,
          campaign_type: campaignType,
        },
      });

      if (!isMountedRef.current) return;

      const trialEndLabel = formatDate(data?.result?.trial_end ?? null);
      toast.success(`Trial réinitialisé (${producerIdentity}) jusqu'au ${trialEndLabel}.`);
      await loadCampaign();
    } catch (err) {
      if (!isMountedRef.current) return;
      toast.error(getResetErrorMessage(err));
    } finally {
      if (isMountedRef.current) {
        setResettingUserId(null);
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

  const maxSlotsHasChanges =
    campaign != null
    && maxSlotsInput.trim() !== (campaign.max_slots != null ? String(campaign.max_slots) : '');

  const minMaxSlots = Math.max(1, campaign?.slots_used ?? 0);

  return (
    <Card className="md:col-span-2 border-zinc-800">
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center gap-2 text-base font-semibold text-white">
          <Users className="h-5 w-5 text-rose-400" />
          Campagne Producteurs — {campaign?.label ?? campaignType}
        </CardTitle>
      </CardHeader>

      <CardContent className="flex flex-col gap-5 p-5 pt-0">
        {campaign && (
          <div
            className={[
              'rounded-lg border p-4',
              campaign.is_active
                ? 'border-emerald-500/25 bg-emerald-500/10'
                : 'border-rose-500/25 bg-rose-500/10',
            ].join(' ')}
          >
            <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <ShieldCheck className={campaign.is_active ? 'h-4 w-4 text-emerald-300' : 'h-4 w-4 text-rose-300'} />
                  <p className="text-sm font-semibold text-white">Campagne serveur actuelle</p>
                  <span
                    className={[
                      'rounded-full border px-2.5 py-0.5 text-xs font-medium',
                      campaign.is_active
                        ? 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200'
                        : 'border-rose-400/30 bg-rose-400/10 text-rose-200',
                    ].join(' ')}
                  >
                    {campaign.is_active ? 'Ouverte' : 'Fermée'}
                  </span>
                </div>
                <p className="mt-2 max-w-3xl text-sm leading-relaxed text-zinc-300">
                  Ce statut modifie <span className="font-mono text-xs text-zinc-200">producer_campaigns.is_active</span>.
                  Fermer la campagne bloque réellement les nouvelles demandes avec ce type de campagne. Cela ne masque pas la vignette marketing.
                </p>
              </div>
              <Button
                type="button"
                variant={campaign.is_active ? 'danger' : 'secondary'}
                size="sm"
                onClick={() => { void handleToggleCampaignActive(); }}
                isLoading={isTogglingCampaign}
                disabled={isTogglingCampaign}
                className="shrink-0"
              >
                {campaign.is_active ? 'Fermer la campagne serveur' : 'Ouvrir la campagne serveur'}
              </Button>
            </div>
            <div className="mt-4 grid gap-3 text-xs sm:grid-cols-3">
              <div className="rounded-md border border-white/10 bg-black/10 px-3 py-2">
                <p className="text-zinc-500">Type</p>
                <p className="mt-1 font-mono text-zinc-100">{campaign.type}</p>
              </div>
              <div className="rounded-md border border-white/10 bg-black/10 px-3 py-2">
                <p className="text-zinc-500">Statut</p>
                <p className={campaign.is_active ? 'mt-1 font-medium text-emerald-200' : 'mt-1 font-medium text-rose-200'}>
                  {campaign.is_active ? 'Ouverte aux nouvelles demandes' : 'Nouvelles demandes bloquées'}
                </p>
              </div>
              <div className="rounded-md border border-white/10 bg-black/10 px-3 py-2">
                <p className="text-zinc-500">Slots max</p>
                <p className="mt-1 font-medium text-zinc-100">{campaign.max_slots ?? 'Illimité'}</p>
              </div>
            </div>
            <form
              className="mt-4 flex flex-col gap-3 rounded-md border border-white/10 bg-black/10 p-3 sm:flex-row sm:items-end"
              onSubmit={(event) => {
                event.preventDefault();
                void handleUpdateMaxSlots();
              }}
            >
              <div className="flex-1">
                <label className="mb-1.5 block text-xs font-medium text-zinc-400">
                  Définir les slots max
                </label>
                <Input
                  type="number"
                  inputMode="numeric"
                  min={minMaxSlots}
                  step={1}
                  value={maxSlotsInput}
                  onChange={(event) => setMaxSlotsInput(event.target.value)}
                  placeholder="Illimité"
                  disabled={isUpdatingMaxSlots}
                  className="text-sm"
                />
              </div>
              <Button
                type="submit"
                variant="secondary"
                size="sm"
                isLoading={isUpdatingMaxSlots}
                disabled={isUpdatingMaxSlots || !maxSlotsHasChanges}
                leftIcon={<Save className="h-3.5 w-3.5" />}
                className="shrink-0"
              >
                Enregistrer
              </Button>
            </form>
          </div>
        )}

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
            disabled={isAssigning || !producerIdentifierInput.trim() || campaign?.is_active === false}
            className="flex shrink-0 items-center gap-2 whitespace-nowrap"
          >
            <UserPlus className="h-4 w-4" />
            {isAssigning ? 'Activation…' : 'Activer Founding'}
          </Button>
        </div>
        {campaign?.is_active === false && (
          <p className="-mt-3 text-xs text-rose-300">
            La campagne serveur est fermée : les nouvelles demandes et activations manuelles sont bloquées tant qu’elle reste fermée.
          </p>
        )}

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
                        <div className="flex justify-end gap-2">
                          <Button
                            type="button"
                            variant="secondary"
                            size="sm"
                            onClick={() => { void handleResetTrial(p); }}
                            disabled={removingUserId !== null || resettingUserId !== null}
                            isLoading={resettingUserId === p.user_id}
                            leftIcon={<RotateCcw className="h-3.5 w-3.5" />}
                          >
                            Réinitialiser
                          </Button>
                          <Button
                            type="button"
                            variant="danger"
                            size="sm"
                            onClick={() => { void handleRemove(p); }}
                            disabled={removingUserId !== null || resettingUserId !== null}
                            isLoading={removingUserId === p.user_id}
                          >
                            Retirer
                          </Button>
                        </div>
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
