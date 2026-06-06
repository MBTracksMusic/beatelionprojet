import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CalendarDays, Trophy } from 'lucide-react';
import { Badge } from '../ui/Badge';
import { Card } from '../ui/Card';
import { useTranslation } from '../../lib/i18n';
import { supabase } from '@/lib/supabase/client';
import type { BattleStatus } from '../../lib/supabase/types';

interface BattleOfTheDayRow {
  battle_id: string;
  slug: string;
  title: string;
  status: BattleStatus;
  producer1_id: string | null;
  producer1_username: string | null;
  producer1_avatar_url: string | null;
  producer2_id: string | null;
  producer2_username: string | null;
  producer2_avatar_url: string | null;
  votes_today: number;
  votes_total: number;
}

type BattleOfTheDayBaseRow = Omit<BattleOfTheDayRow, 'producer1_avatar_url' | 'producer2_avatar_url'>;

interface BattleOfTheDayProfileRow {
  user_id: string | null;
  username: string | null;
  avatar_url: string | null;
}

const BATTLE_OF_THE_DAY_BASE_SELECT =
  'battle_id, slug, title, status, producer1_id, producer1_username, producer2_id, producer2_username, votes_today, votes_total' as const;

const BATTLE_OF_THE_DAY_AVATAR_SELECT =
  `${BATTLE_OF_THE_DAY_BASE_SELECT}, producer1_avatar_url, producer2_avatar_url` as const;

function getStatusLabel(status: BattleStatus, t: ReturnType<typeof useTranslation>['t']) {
  if (status === 'active' || status === 'voting') return t('battleDetail.statusActive');
  if (status === 'completed') return t('battleDetail.statusCompleted');
  if (status === 'awaiting_admin') return t('battleDetail.statusAwaitingAdmin');
  if (status === 'pending_acceptance') return t('battleDetail.statusPendingAcceptance');
  if (status === 'rejected') return t('battleDetail.statusRejected');
  if (status === 'cancelled') return t('battleDetail.statusCancelled');
  return t('battleDetail.statusPending');
}

function getStatusVariant(status: BattleStatus): 'default' | 'success' | 'warning' | 'danger' | 'info' | 'premium' {
  if (status === 'active' || status === 'voting') return 'success';
  if (status === 'completed' || status === 'awaiting_admin' || status === 'approved') return 'info';
  if (status === 'cancelled' || status === 'rejected') return 'danger';
  return 'warning';
}

function getProducerInitials(name: string) {
  const parts = name.trim().split(/[\s._-]+/).filter(Boolean);
  const initials = parts.length > 1 ? `${parts[0][0]}${parts[1][0]}` : name.trim().slice(0, 2);
  return initials.toUpperCase();
}

async function enrichBattleProfileAvatars(row: BattleOfTheDayRow | null): Promise<BattleOfTheDayRow | null> {
  if (!row) return row;

  const uniqueProducerIds = [...new Set([row.producer1_id, row.producer2_id].filter((value): value is string => Boolean(value)))];
  if (uniqueProducerIds.length === 0) return row;

  const { data, error } = await supabase
    .from('public_producer_profiles')
    .select('user_id, username, avatar_url')
    .in('user_id', uniqueProducerIds);

  if (error || !Array.isArray(data)) {
    if (error) {
      console.warn('Unable to enrich battle of the day avatars:', error);
    }
    return row;
  }

  const profilesById = new Map<string, BattleOfTheDayProfileRow>();
  for (const profile of data as BattleOfTheDayProfileRow[]) {
    if (typeof profile.user_id === 'string' && profile.user_id.length > 0) {
      profilesById.set(profile.user_id, profile);
    }
  }

  const producer1 = row.producer1_id ? profilesById.get(row.producer1_id) : undefined;
  const producer2 = row.producer2_id ? profilesById.get(row.producer2_id) : undefined;

  return {
    ...row,
    producer1_username: row.producer1_username ?? producer1?.username ?? null,
    producer1_avatar_url: row.producer1_avatar_url ?? producer1?.avatar_url ?? null,
    producer2_username: row.producer2_username ?? producer2?.username ?? null,
    producer2_avatar_url: row.producer2_avatar_url ?? producer2?.avatar_url ?? null,
  };
}

interface ProducerPillProps {
  avatarUrl: string | null;
  name: string;
}

function ProducerPill({ avatarUrl, name }: ProducerPillProps) {
  return (
    <span className="inline-flex min-w-0 max-w-full items-center gap-2 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1 text-sm text-zinc-300">
      {avatarUrl ? (
        <img
          src={avatarUrl}
          alt={name}
          className="h-7 w-7 flex-none rounded-full border border-zinc-700 object-cover"
          loading="lazy"
        />
      ) : (
        <span className="flex h-7 w-7 flex-none items-center justify-center rounded-full border border-zinc-700 bg-zinc-800 text-[11px] font-bold text-zinc-300">
          {getProducerInitials(name)}
        </span>
      )}
      <span className="min-w-0 max-w-[11rem] truncate">{name}</span>
    </span>
  );
}

export function HomeBattleOfTheDay() {
  const { t } = useTranslation();
  const [battle, setBattle] = useState<BattleOfTheDayRow | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let isCancelled = false;

    async function fetchBattleOfTheDay() {
      setIsLoading(true);

      let data: BattleOfTheDayRow | null = null;
      let error: unknown = null;

      const viewRes = await supabase
        .from('battle_of_the_day')
        .select(BATTLE_OF_THE_DAY_AVATAR_SELECT)
        .maybeSingle();

      if (viewRes.error) {
        const fallbackRes = await supabase
          .from('battle_of_the_day')
          .select(BATTLE_OF_THE_DAY_BASE_SELECT)
          .maybeSingle();

        const fallbackData = fallbackRes.data as unknown as BattleOfTheDayBaseRow | null;
        error = fallbackRes.error;
        data = fallbackData
          ? await enrichBattleProfileAvatars({
              ...fallbackData,
              producer1_avatar_url: null,
              producer2_avatar_url: null,
            })
          : null;
      } else {
        data = (viewRes.data as BattleOfTheDayRow | null) ?? null;
      }

      if (isCancelled) return;

      if (error) {
        console.error('Error loading battle of the day:', error);
        setBattle(null);
      } else {
        setBattle(data);
      }

      setIsLoading(false);
    }

    void fetchBattleOfTheDay();

    return () => {
      isCancelled = true;
    };
  }, []);

  return (
    <section className="py-12 md:py-20 bg-zinc-900/40 border-y border-zinc-900">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center gap-2 mb-2">
          <Trophy className="w-5 h-5 text-amber-400" />
          <h2 className="text-3xl font-bold text-white">{t('home.battleOfTheDayTitle')}</h2>
        </div>
        <p className="text-zinc-400 mb-8">{t('home.battleOfTheDaySubtitle')}</p>

        {isLoading ? (
          <Card className="h-32 animate-pulse border-zinc-800 bg-zinc-900" />
        ) : !battle ? (
          <Card className="text-zinc-400">{t('home.noBattleOfTheDay')}</Card>
        ) : (
          <Link to={`/battles/${battle.slug}`}>
            <Card variant="interactive" className="border-zinc-800 hover:border-amber-500/50">
              <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
                <div className="space-y-2">
                  <p className="text-xl font-semibold text-white">{battle.title}</p>
                  <div className="flex flex-wrap items-center gap-2">
                    <ProducerPill
                      avatarUrl={battle.producer1_avatar_url}
                      name={battle.producer1_username || t('home.producerOne')}
                    />
                    <span className="text-xs font-semibold uppercase text-zinc-500">{t('battles.vs')}</span>
                    <ProducerPill
                      avatarUrl={battle.producer2_avatar_url}
                      name={battle.producer2_username || t('home.producerTwo')}
                    />
                  </div>
                  <div className="flex flex-wrap items-center gap-2 text-xs text-zinc-300">
                    <span className="inline-flex items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1">
                      <CalendarDays className="w-3.5 h-3.5 text-amber-400" />
                      {t('home.votesToday', { count: battle.votes_today })}
                    </span>
                    <span className="inline-flex items-center gap-1 rounded-full border border-zinc-800 bg-zinc-950 px-2 py-1">
                      {t('home.votesTotal', { count: battle.votes_total })}
                    </span>
                  </div>
                </div>
                <Badge variant={getStatusVariant(battle.status)}>{getStatusLabel(battle.status, t)}</Badge>
              </div>
            </Card>
          </Link>
        )}
      </div>
    </section>
  );
}
