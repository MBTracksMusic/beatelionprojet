import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Crown, Lock, MessageSquarePlus, Pin, ShieldCheck, Swords } from 'lucide-react';
import { Badge } from '../components/ui/Badge';
import { Button } from '../components/ui/Button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../components/ui/Card';
import { ReputationBadge } from '../components/reputation/ReputationBadge';
import { Input } from '../components/ui/Input';
import { Modal } from '../components/ui/Modal';
import { useAuth } from '../lib/auth/hooks';
import { getForumFunctionErrorCode, getForumFunctionErrorMessage, useForumActions, useForumTopics } from '../lib/forum/hooks';
import { useMyReputation } from '../lib/reputation/hooks';
import { meetsRankRequirement } from '../lib/reputation/utils';
import { formatRelativeTime } from '../lib/utils/format';

const PAGE_SIZE = 20;

export function ForumCategoryPage() {
  const navigate = useNavigate();
  const { categorySlug } = useParams<{ categorySlug: string }>();
  const { user } = useAuth();
  const { reputation } = useMyReputation();
  const [page, setPage] = useState(1);
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');

  const { category, topics, totalCount, totalPages, isLoading, error, refresh } = useForumTopics({
    categorySlug,
    page,
    pageSize: PAGE_SIZE,
  });
  const { createTopic, isSubmitting } = useForumActions();
  const isRankLocked = category ? !meetsRankRequirement(reputation?.rank_tier, category.required_rank_tier) : false;

  const paginationLabel = useMemo(() => {
    if (totalCount === 0) return '0 topic';
    const from = (page - 1) * PAGE_SIZE + 1;
    const to = Math.min(page * PAGE_SIZE, totalCount);
    return `${from}-${to} sur ${totalCount} topics`;
  }, [page, totalCount]);

  const resetCreateForm = () => {
    setTitle('');
    setContent('');
  };

  const handleCreateTopic = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!category || isSubmitting) return;

    const trimmedTitle = title.trim();
    const trimmedContent = content.trim();

    if (!trimmedTitle || !trimmedContent) {
      toast.error('Le titre et le premier message sont obligatoires.');
      return;
    }

    try {
      const topic = await createTopic({
        categorySlug: category.slug,
        title: trimmedTitle,
        content: trimmedContent,
      });

      resetCreateForm();
      setIsCreateOpen(false);
      if (topic.status === 'review') {
        toast.success('Topic cree et place en attente de moderation.');
      } else {
        toast.success('Topic cree.');
      }
      navigate(`/forum/${topic.category_slug}/${topic.topic_slug}`);
    } catch (createError) {
      console.error('Failed to create forum topic', createError);
      const errorCode = getForumFunctionErrorCode(createError);
      if (errorCode === 'blocked') {
        toast.error('Contenu refuse.');
        return;
      }

      toast.error(getForumFunctionErrorMessage(createError, 'Impossible de creer ce topic.'));
    }
  };

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-6xl mx-auto px-4 space-y-8">
        <div className="space-y-4">
          <Link to="/forum" className="inline-flex items-center gap-2 text-zinc-400 hover:text-white">
            <ChevronLeft className="h-4 w-4" />
            Retour au forum
          </Link>
          <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
            <div className="space-y-2">
              <div className="flex flex-wrap items-center gap-2">
                <h1 className="text-3xl font-bold text-white">{category?.name || 'Categorie forum'}</h1>
                {category?.is_premium_only && (
                  <Badge variant="premium">
                    <Crown className="h-3 w-3" />
                    Premium
                  </Badge>
                )}
                {category?.is_competitive && (
                  <Badge variant="info">
                    <Swords className="h-3 w-3" />
                    Competitif
                  </Badge>
                )}
                {category?.required_rank_tier && (
                  <Badge variant="warning">
                    <ShieldCheck className="h-3 w-3" />
                    Rang min. {category.required_rank_tier}
                  </Badge>
                )}
              </div>
              <p className="text-zinc-400">
                {category?.description || 'Parcourez les discussions les plus recentes.'}
              </p>
              {category && (
                <div className="flex flex-wrap gap-2 text-xs text-zinc-500">
                  <span>XP x{category.xp_multiplier ?? 1}</span>
                  <span>Moderation {category.moderation_strictness ?? 'normal'}</span>
                  <span>{category.allow_links === false ? 'Liens interdits' : 'Liens autorises'}</span>
                  <span>{category.allow_media === false ? 'Media interdits' : 'Media autorises'}</span>
                </div>
              )}
            </div>
            {user && !isRankLocked && (
              <Button leftIcon={<MessageSquarePlus className="h-4 w-4" />} onClick={() => setIsCreateOpen(true)}>
                Nouveau topic
              </Button>
            )}
          </div>
        </div>

        {isRankLocked && category?.required_rank_tier && (
          <Card className="border-amber-900 bg-amber-950/20">
            <CardContent className="text-sm text-amber-300">
              Cette categorie est reservee au rang {category.required_rank_tier} minimum.
            </CardContent>
          </Card>
        )}

        <div className="flex items-center justify-between text-sm text-zinc-400">
          <span>{paginationLabel}</span>
          <Button variant="outline" size="sm" onClick={() => void refresh()}>
            Actualiser
          </Button>
        </div>

        {isLoading && (
          <div className="grid gap-4">
            {Array.from({ length: 4 }).map((_, index) => (
              <Card key={index} className="border-zinc-800">
                <div className="h-28 animate-pulse rounded-xl bg-zinc-900" />
              </Card>
            ))}
          </div>
        )}

        {error && (
          <Card className="border-red-900 bg-red-950/20">
            <CardContent className="text-sm text-red-300">{error}</CardContent>
          </Card>
        )}

        {!isLoading && !error && topics.length === 0 && (
          <Card className="border-zinc-800">
            <CardContent className="py-12 text-center text-zinc-400">
              Aucun topic dans cette categorie pour le moment.
            </CardContent>
          </Card>
        )}

        <div className="grid gap-4">
          {topics.map((topic) => (
            <Link key={topic.id} to={`/forum/${category?.slug ?? categorySlug}/${topic.slug}`} className="block">
              <Card variant="interactive" className="border-zinc-800">
                <CardHeader className="mb-2 flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div className="space-y-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <CardTitle>{topic.title}</CardTitle>
                      {topic.is_pinned && (
                        <Badge variant="info">
                          <Pin className="h-3 w-3" />
                          Epingle
                        </Badge>
                      )}
                      {topic.is_locked && (
                        <Badge variant="warning">
                          <Lock className="h-3 w-3" />
                          Verrouille
                        </Badge>
                      )}
                    </div>
                    <CardDescription>
                      Par {topic.author?.username || `Membre ${topic.user_id.slice(0, 8)}`} •
                      {' '}
                      cree {formatRelativeTime(topic.created_at)}
                    </CardDescription>
                    {topic.author && (
                      <ReputationBadge
                        compact
                        rankTier={topic.author.rank_tier}
                        level={topic.author.level}
                        xp={topic.author.xp}
                      />
                    )}
                  </div>
                  <div className="text-right text-sm text-zinc-400">
                    <div>{topic.post_count} reponses</div>
                    <div>Dernier message {formatRelativeTime(topic.last_post_at)}</div>
                  </div>
                </CardHeader>
              </Card>
            </Link>
          ))}
        </div>

        {totalPages > 1 && (
          <div className="flex items-center justify-between gap-3">
            <Button
              variant="outline"
              onClick={() => setPage((prev) => Math.max(1, prev - 1))}
              disabled={page <= 1}
              leftIcon={<ChevronLeft className="h-4 w-4" />}
            >
              Page precedente
            </Button>
            <span className="text-sm text-zinc-400">
              Page {page} / {totalPages}
            </span>
            <Button
              variant="outline"
              onClick={() => setPage((prev) => Math.min(totalPages, prev + 1))}
              disabled={page >= totalPages}
              rightIcon={<ChevronRight className="h-4 w-4" />}
            >
              Page suivante
            </Button>
          </div>
        )}
      </div>

      <Modal
        isOpen={isCreateOpen}
        onClose={() => {
          if (isSubmitting) return;
          setIsCreateOpen(false);
          resetCreateForm();
        }}
        title="Nouveau topic"
        description="Le premier message sera publie immediatement dans la discussion."
        size="lg"
      >
        <form onSubmit={handleCreateTopic} className="space-y-4">
          <Input
            label="Titre"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="Ex: Comment compresser un master sans casser les transients ?"
            disabled={isSubmitting}
          />
          <div>
            <label htmlFor="forum-topic-content" className="block text-sm font-medium text-zinc-300 mb-1.5">
              Premier message
            </label>
            <textarea
              id="forum-topic-content"
              value={content}
              onChange={(event) => setContent(event.target.value)}
              disabled={isSubmitting}
              rows={8}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-3 text-white placeholder-zinc-500 focus:border-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500/50"
              placeholder="Exposez clairement votre question ou votre retour d'experience."
            />
          </div>
          <div className="flex justify-end gap-3">
            <Button
              type="button"
              variant="ghost"
              onClick={() => {
                if (isSubmitting) return;
                setIsCreateOpen(false);
                resetCreateForm();
              }}
            >
              Annuler
            </Button>
            <Button type="submit" isLoading={isSubmitting}>
              Publier le topic
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
