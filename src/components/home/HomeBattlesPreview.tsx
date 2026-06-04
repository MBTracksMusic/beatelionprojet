import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { ArrowRight, ChevronLeft, ChevronRight, Swords } from 'lucide-react';
import { motion } from 'framer-motion';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { Card } from '../ui/Card';
import { useTranslation, type TranslationKey } from '../../lib/i18n';
import { supabase } from '@/lib/supabase/client';
import type { BattleStatus } from '../../lib/supabase/types';

interface HomeBattleProducer {
  id: string;
  username: string | null;
  avatar_url: string | null;
}

interface HomeBattleRow {
  id: string;
  title: string;
  slug: string;
  status: BattleStatus;
  producer1_id: string;
  producer2_id: string | null;
  votes_producer1: number;
  votes_producer2: number;
  producer1?: HomeBattleProducer;
  producer2?: HomeBattleProducer;
}

interface HomeBattlesPreviewRpcRow {
  id: string;
  title: string;
  slug: string;
  status: BattleStatus;
  producer1_id: string;
  producer1_username: string | null;
  producer2_id: string | null;
  producer2_username: string | null;
  votes_producer1: number | null;
  votes_producer2: number | null;
}

const visibleStatuses: BattleStatus[] = ['active', 'voting', 'completed', 'awaiting_admin', 'approved', 'pending_acceptance'];

const badgeByStatus: Record<BattleStatus, 'default' | 'success' | 'warning' | 'danger' | 'info' | 'premium'> = {
  pending: 'warning',
  pending_acceptance: 'warning',
  awaiting_admin: 'info',
  approved: 'info',
  active: 'success',
  voting: 'success',
  completed: 'info',
  cancelled: 'danger',
  rejected: 'danger',
};

interface HomeProducerProfileRow {
  user_id: string | null;
  username: string | null;
  avatar_url: string | null;
}

function toStatusLabel(status: BattleStatus): TranslationKey {
  if (status === 'active' || status === 'voting') return 'battleDetail.statusActive';
  if (status === 'completed') return 'battleDetail.statusCompleted';
  if (status === 'pending_acceptance') return 'battleDetail.statusPendingAcceptance';
  if (status === 'awaiting_admin') return 'battleDetail.statusAwaitingAdmin';
  if (status === 'approved') return 'battleDetail.statusApproved';
  if (status === 'rejected') return 'battleDetail.statusRejected';
  if (status === 'cancelled') return 'battleDetail.statusCancelled';
  return 'battleDetail.statusPending';
}

function getProducerInitials(name: string) {
  const parts = name.trim().split(/[\s._-]+/).filter(Boolean);
  const initials = parts.length > 1 ? `${parts[0][0]}${parts[1][0]}` : name.trim().slice(0, 2);
  return initials.toUpperCase();
}

async function fetchHomeProducerProfilesMap(
  userIds: Array<string | null | undefined>
): Promise<Map<string, HomeProducerProfileRow>> {
  const uniqueIds = [...new Set(userIds.filter((value): value is string => typeof value === 'string' && value.length > 0))];

  if (uniqueIds.length === 0) {
    return new Map();
  }

  const { data, error } = await supabase
    .from('public_producer_profiles')
    .select('user_id, username, avatar_url')
    .in('user_id', uniqueIds);

  if (error || !Array.isArray(data)) {
    if (error) {
      console.warn('Unable to enrich home battle producer avatars:', error);
    }
    return new Map();
  }

  const profilesById = new Map<string, HomeProducerProfileRow>();
  for (const row of data as HomeProducerProfileRow[]) {
    if (typeof row.user_id === 'string' && row.user_id.length > 0) {
      profilesById.set(row.user_id, row);
    }
  }

  return profilesById;
}

async function enrichBattleProducers(rows: HomeBattleRow[]): Promise<HomeBattleRow[]> {
  if (rows.length === 0) return rows;

  const producerProfilesMap = await fetchHomeProducerProfilesMap(
    rows.flatMap((row) => [row.producer1_id, row.producer2_id])
  );

  return rows.map((row) => {
    const producer1 = producerProfilesMap.get(row.producer1_id);
    const producer2 = row.producer2_id ? producerProfilesMap.get(row.producer2_id) : undefined;

    return {
      ...row,
      producer1: {
        id: row.producer1_id,
        username: producer1?.username ?? row.producer1?.username ?? null,
        avatar_url: producer1?.avatar_url ?? row.producer1?.avatar_url ?? null,
      },
      producer2: row.producer2_id
        ? {
            id: row.producer2_id,
            username: producer2?.username ?? row.producer2?.username ?? null,
            avatar_url: producer2?.avatar_url ?? row.producer2?.avatar_url ?? null,
          }
        : undefined,
    };
  });
}

interface ProducerPreviewProps {
  align: 'left' | 'right';
  fallbackLabel: string;
  voteCount: number;
  producer?: HomeBattleProducer;
}

function ProducerPreview({ align, fallbackLabel, voteCount, producer }: ProducerPreviewProps) {
  const { t } = useTranslation();
  const displayName = producer?.username || fallbackLabel;
  const alignClass = align === 'right' ? 'sm:items-end sm:text-right' : 'sm:items-start sm:text-left';
  const voteClass = align === 'right' ? 'text-orange-300' : 'text-rose-300';

  return (
    <div className={`flex min-w-0 items-center gap-3 text-left sm:flex-col sm:gap-0 ${alignClass}`}>
      {producer?.avatar_url ? (
        <img
          src={producer.avatar_url}
          alt={displayName}
          className="h-12 w-12 rounded-full border border-zinc-700 object-cover"
          loading="lazy"
        />
      ) : (
        <div className="flex h-12 w-12 items-center justify-center rounded-full border border-zinc-700 bg-zinc-800 text-sm font-bold text-zinc-300">
          {getProducerInitials(displayName)}
        </div>
      )}
      <div className="min-w-0 flex-1 sm:mt-2 sm:max-w-full sm:flex-none">
        <p className="text-[13px] font-semibold leading-snug text-white [overflow-wrap:anywhere]">
          {displayName}
        </p>
        <p className={`mt-1 text-xs font-semibold ${voteClass}`}>
          {voteCount} {t(voteCount === 1 ? 'home.voteSingular' : 'home.votePlural')}
        </p>
      </div>
    </div>
  );
}

export function HomeBattlesPreview() {
  const { t } = useTranslation();
  const [battles, setBattles] = useState<HomeBattleRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const scrollRef = useRef<HTMLDivElement>(null);

  const scroll = (dir: 'left' | 'right') => {
    scrollRef.current?.scrollBy({ left: dir === 'left' ? -400 : 400, behavior: 'smooth' });
  };

  useEffect(() => {
    let isCancelled = false;

    async function fetchBattles() {
      setIsLoading(true);

      let previewBattles: HomeBattleRow[] = [];
      const rpcRes = await supabase.rpc('get_public_home_battles_preview' as never, { p_limit: 3 } as never);
      if (!rpcRes.error && Array.isArray(rpcRes.data)) {
        previewBattles = (rpcRes.data as HomeBattlesPreviewRpcRow[]).map((row) => ({
          id: row.id,
          title: row.title,
          slug: row.slug,
          status: row.status,
          producer1_id: row.producer1_id,
          producer2_id: row.producer2_id,
          votes_producer1: row.votes_producer1 ?? 0,
          votes_producer2: row.votes_producer2 ?? 0,
          producer1: {
            id: row.producer1_id,
            username: row.producer1_username,
            avatar_url: null,
          },
          producer2: row.producer2_id
            ? {
                id: row.producer2_id,
                username: row.producer2_username,
                avatar_url: null,
              }
            : undefined,
        }));
      }

      if (previewBattles.length === 0) {
        const { data, error } = await supabase
          .from('battles')
          .select(`
            id,
            title,
            slug,
            status,
            producer1_id,
            producer2_id,
            votes_producer1,
            votes_producer2
          `)
          .in('status', visibleStatuses)
          .order('created_at', { ascending: false })
          .limit(3);

        if (error) {
          console.error('Error fetching home battles preview:', error);
          if (rpcRes.error) {
            console.error('Error fetching home battles preview RPC:', rpcRes.error);
          }
          const { data: spotlightRow, error: spotlightError } = await supabase
            .from('battle_of_the_day' as never)
            .select('battle_id, slug, title, status, producer1_id, producer1_username, producer2_id, producer2_username')
            .maybeSingle();
          if (!spotlightError && spotlightRow) {
            const spotlight = spotlightRow as unknown as Record<string, unknown>;
            previewBattles = [
              {
                id: String(spotlight.battle_id),
                title: String(spotlight.title),
                slug: String(spotlight.slug),
                status: (spotlight.status as BattleStatus) ?? 'active',
                producer1_id: String(spotlight.producer1_id),
                producer2_id: (spotlight.producer2_id as string | null) ?? null,
                votes_producer1: 0,
                votes_producer2: 0,
                producer1: {
                  id: String(spotlight.producer1_id),
                  username: (spotlight.producer1_username as string | null) ?? null,
                  avatar_url: null,
                },
                producer2: spotlight.producer2_id
                  ? {
                      id: String(spotlight.producer2_id),
                      username: (spotlight.producer2_username as string | null) ?? null,
                      avatar_url: null,
                    }
                  : undefined,
              },
            ];
          }
        } else {
          previewBattles = ((data as HomeBattleRow[] | null) ?? []);
        }
      }

      previewBattles = await enrichBattleProducers(previewBattles);

      if (!isCancelled) {
        if (rpcRes.error && previewBattles.length > 0) {
          console.warn('Home battles preview RPC failed, fallback succeeded:', rpcRes.error);
        }
        setBattles(previewBattles);
        setIsLoading(false);
      }
    }

    void fetchBattles();

    return () => {
      isCancelled = true;
    };
  }, []);

  return (
    <motion.section
      className="py-12 md:py-20 bg-zinc-950"
      initial={{ opacity: 0, y: 24 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-80px' }}
      transition={{ duration: 0.6, ease: 'easeOut' }}
    >
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="mb-8 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <Swords className="w-5 h-5 text-rose-400" />
              <h2 className="text-3xl font-bold text-white">{t('battles.title')}</h2>
            </div>
            <p className="text-zinc-400 text-sm">{t('home.latestBattlesSubtitle')}</p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              aria-label="Scroll left"
              onClick={() => scroll('left')}
              className="w-11 h-11 rounded-full border border-zinc-700 bg-zinc-800 flex items-center justify-center text-zinc-400 hover:text-white hover:border-zinc-500 transition-colors"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            <button
              type="button"
              aria-label="Scroll right"
              onClick={() => scroll('right')}
              className="w-11 h-11 rounded-full border border-zinc-700 bg-zinc-800 flex items-center justify-center text-zinc-400 hover:text-white hover:border-zinc-500 transition-colors"
            >
              <ChevronRight className="w-4 h-4" />
            </button>
            <Link to="/battles">
              <Button variant="ghost" rightIcon={<ArrowRight className="w-4 h-4" />}>
                {t('home.viewAllBattles')}
              </Button>
            </Link>
          </div>
        </div>

        {isLoading ? (
          <div className="flex gap-4 overflow-hidden">
            {[...Array(3)].map((_, i) => (
              <div key={i} className="w-[min(88vw,24rem)] flex-shrink-0 space-y-4 rounded-lg border border-zinc-800 bg-zinc-900 p-5 animate-pulse">
                <div className="h-5 bg-zinc-800 rounded w-2/3" />
                <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-start gap-3">
                  <div className="space-y-2">
                    <div className="h-12 w-12 rounded-full bg-zinc-800" />
                    <div className="h-4 bg-zinc-800 rounded w-24" />
                  </div>
                  <div className="mt-4 h-6 w-8 rounded-full bg-zinc-800" />
                  <div className="flex flex-col items-end space-y-2">
                    <div className="h-12 w-12 rounded-full bg-zinc-800" />
                    <div className="h-4 bg-zinc-800 rounded w-24" />
                  </div>
                </div>
                <div className="h-7 bg-zinc-800 rounded w-24" />
              </div>
            ))}
          </div>
        ) : battles.length === 0 ? (
          <Card className="text-zinc-400">{t('home.noPublicBattles')}</Card>
        ) : (
          <div ref={scrollRef} className="flex gap-4 overflow-x-auto hide-scrollbar pb-2">
            {battles.map((battle, index) => (
              <Link key={battle.id} to={`/battles/${battle.slug}`} className="w-[min(88vw,24rem)] flex-shrink-0">
                <motion.div
                  initial={{ opacity: 0, y: 16 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true }}
                  transition={{ duration: 0.4, delay: index * 0.08 }}
                  whileHover={{ y: -4 }}
                  className="flex h-full min-h-[184px] flex-col rounded-lg border border-zinc-800 bg-zinc-900/80 p-5 transition-colors duration-200 hover:border-rose-500/40"
                >
                  <div className="flex items-start justify-between gap-3">
                    <p className="line-clamp-2 min-w-0 text-base font-semibold leading-snug text-white">
                      {battle.title}
                    </p>
                    <Badge variant={badgeByStatus[battle.status]} className="shrink-0">
                      {t(toStatusLabel(battle.status))}
                    </Badge>
                  </div>

                  <div className="mt-5 flex flex-1 flex-col gap-3 sm:grid sm:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] sm:items-start">
                    <ProducerPreview
                      align="left"
                      producer={battle.producer1}
                      fallbackLabel={t('home.producerOne')}
                      voteCount={battle.votes_producer1}
                    />
                    <span className="self-center rounded-full bg-rose-500/10 px-2 py-1 text-xs font-bold text-rose-400 sm:mt-3">
                      VS
                    </span>
                    <ProducerPreview
                      align="right"
                      producer={battle.producer2}
                      fallbackLabel={t('home.producerTwo')}
                      voteCount={battle.votes_producer2}
                    />
                  </div>
                </motion.div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </motion.section>
  );
}
