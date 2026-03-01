import { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Link, useParams } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Lock } from 'lucide-react';
import { Badge } from '../components/ui/Badge';
import { Button } from '../components/ui/Button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../components/ui/Card';
import { useAuth } from '../lib/auth/hooks';
import { useForumActions, useForumPosts } from '../lib/forum/hooks';
import { formatDateTime } from '../lib/utils/format';

const PAGE_SIZE = 20;

export function ForumTopicPage() {
  const { categorySlug, topicSlug } = useParams<{ categorySlug: string; topicSlug: string }>();
  const { user } = useAuth();
  const [page, setPage] = useState(1);
  const [reply, setReply] = useState('');

  const { category, topic, posts, totalCount, totalPages, isLoading, error, refresh } = useForumPosts({
    categorySlug,
    topicSlug,
    page,
    pageSize: PAGE_SIZE,
  });
  const { createReply, isSubmitting } = useForumActions();

  const paginationLabel = useMemo(() => {
    if (totalCount === 0) return '0 message';
    const from = (page - 1) * PAGE_SIZE + 1;
    const to = Math.min(page * PAGE_SIZE, totalCount);
    return `${from}-${to} sur ${totalCount} messages`;
  }, [page, totalCount]);

  const handleReply = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!topic || isSubmitting) return;

    const trimmedReply = reply.trim();
    if (!trimmedReply) {
      toast.error('Votre reponse ne peut pas etre vide.');
      return;
    }

    try {
      await createReply({
        topicId: topic.id,
        content: trimmedReply,
      });
      setReply('');
      toast.success('Reponse publiee.');
      await refresh();
      setPage(totalPages);
    } catch (replyError) {
      console.error('Failed to create forum reply', replyError);
      toast.error('Impossible de publier la reponse.');
    }
  };

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-5xl mx-auto px-4 space-y-8">
        <div className="space-y-4">
          <Link
            to={category ? `/forum/${category.slug}` : '/forum'}
            className="inline-flex items-center gap-2 text-zinc-400 hover:text-white"
          >
            <ChevronLeft className="h-4 w-4" />
            Retour a la categorie
          </Link>
          <div className="space-y-2">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-3xl font-bold text-white">{topic?.title || 'Topic forum'}</h1>
              {topic?.is_locked && (
                <Badge variant="warning">
                  <Lock className="h-3 w-3" />
                  Verrouille
                </Badge>
              )}
            </div>
            <p className="text-zinc-400">
              {category?.name || 'Forum'} • {paginationLabel}
            </p>
          </div>
        </div>

        <div className="flex items-center justify-between text-sm text-zinc-400">
          <span>{paginationLabel}</span>
          <Button variant="outline" size="sm" onClick={() => void refresh()}>
            Actualiser
          </Button>
        </div>

        {isLoading && (
          <div className="grid gap-4">
            {Array.from({ length: 3 }).map((_, index) => (
              <Card key={index} className="border-zinc-800">
                <div className="h-40 animate-pulse rounded-xl bg-zinc-900" />
              </Card>
            ))}
          </div>
        )}

        {error && (
          <Card className="border-red-900 bg-red-950/20">
            <CardContent className="text-sm text-red-300">{error}</CardContent>
          </Card>
        )}

        <div className="grid gap-4">
          {posts.map((post, index) => (
            <Card key={post.id} className="border-zinc-800">
              <CardHeader className="mb-3 flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                <div>
                  <CardTitle className="text-base">
                    {post.author?.username || `Membre ${post.user_id.slice(0, 8)}`}
                  </CardTitle>
                  <CardDescription>
                    Message #{(page - 1) * PAGE_SIZE + index + 1} • {formatDateTime(post.created_at)}
                  </CardDescription>
                </div>
                {post.edited_at && (
                  <Badge variant="info">Edite le {formatDateTime(post.edited_at)}</Badge>
                )}
              </CardHeader>
              <CardContent>
                <p className="whitespace-pre-wrap text-sm leading-7 text-zinc-200">
                  {post.is_deleted ? 'Ce message a ete supprime.' : post.content}
                </p>
              </CardContent>
            </Card>
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

        {user ? (
          topic?.is_locked ? (
            <Card className="border-amber-900 bg-amber-950/20">
              <CardContent className="text-sm text-amber-300">
                Ce topic est verrouille. Aucune nouvelle reponse n'est autorisee.
              </CardContent>
            </Card>
          ) : (
            <Card className="border-zinc-800">
              <CardHeader>
                <CardTitle>Repondre</CardTitle>
                <CardDescription>Votre message sera publie a la suite de la discussion.</CardDescription>
              </CardHeader>
              <CardContent>
                <form onSubmit={handleReply} className="space-y-4">
                  <textarea
                    value={reply}
                    onChange={(event) => setReply(event.target.value)}
                    disabled={isSubmitting}
                    rows={7}
                    className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-3 text-white placeholder-zinc-500 focus:border-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500/50"
                    placeholder="Partagez votre reponse, votre retour ou une precision utile."
                  />
                  <div className="flex justify-end">
                    <Button type="submit" isLoading={isSubmitting}>
                      Publier la reponse
                    </Button>
                  </div>
                </form>
              </CardContent>
            </Card>
          )
        ) : (
          <Card className="border-zinc-800">
            <CardContent className="py-8 text-center text-zinc-400">
              Connectez-vous pour repondre a ce topic.
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
