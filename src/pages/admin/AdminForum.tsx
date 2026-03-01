import { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Button } from '../../components/ui/Button';
import { Card } from '../../components/ui/Card';
import { supabase } from '../../lib/supabase/client';

type ForumCategoryRow = {
  id: string;
  name: string;
  slug: string;
};

type ForumTopicRow = {
  id: string;
  category_id: string;
  user_id: string;
  title: string;
  slug: string;
  created_at: string;
  updated_at?: string | null;
};

type ForumPostRow = {
  id: string;
  topic_id: string;
  user_id: string;
  content: string;
  created_at: string;
  updated_at?: string | null;
};

const FORUM_CATEGORIES_TABLE = 'forum_categories' as any;
const FORUM_TOPICS_TABLE = 'forum_topics' as any;
const FORUM_POSTS_TABLE = 'forum_posts' as any;

export function AdminForumPage() {
  const [topics, setTopics] = useState<ForumTopicRow[]>([]);
  const [posts, setPosts] = useState<ForumPostRow[]>([]);
  const [categories, setCategories] = useState<ForumCategoryRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [actionKey, setActionKey] = useState<string | null>(null);

  const loadForumModeration = useCallback(async () => {
    setIsLoading(true);

    const [{ data: categoriesData, error: categoriesError }, { data: topicsData, error: topicsError }, { data: postsData, error: postsError }] =
      await Promise.all([
        supabase.from(FORUM_CATEGORIES_TABLE).select('id, name, slug').order('name', { ascending: true }),
        supabase.from(FORUM_TOPICS_TABLE).select('id, category_id, user_id, title, slug, created_at, updated_at').order('created_at', { ascending: false }).limit(50),
        supabase.from(FORUM_POSTS_TABLE).select('id, topic_id, user_id, content, created_at, updated_at').order('created_at', { ascending: false }).limit(50),
      ]);

    if (categoriesError || topicsError || postsError) {
      console.error('Error loading forum moderation data', { categoriesError, topicsError, postsError });
      toast.error('Impossible de charger la moderation forum.');
      setCategories([]);
      setTopics([]);
      setPosts([]);
      setIsLoading(false);
      return;
    }

    setCategories((categoriesData as unknown as ForumCategoryRow[] | null) ?? []);
    setTopics((topicsData as unknown as ForumTopicRow[] | null) ?? []);
    setPosts((postsData as unknown as ForumPostRow[] | null) ?? []);
    setIsLoading(false);
  }, []);

  useEffect(() => {
    void loadForumModeration();
  }, [loadForumModeration]);

  const categoryMap = useMemo(() => new Map(categories.map((category) => [category.id, category])), [categories]);
  const topicMap = useMemo(() => new Map(topics.map((topic) => [topic.id, topic])), [topics]);

  const deleteTopic = async (topicId: string) => {
    setActionKey(`topic:${topicId}`);
    const { error } = await supabase.from(FORUM_TOPICS_TABLE).delete().eq('id', topicId);

    if (error) {
      console.error('Error deleting forum topic', error);
      toast.error('Suppression du topic impossible.');
      setActionKey(null);
      return;
    }

    setTopics((prev) => prev.filter((topic) => topic.id !== topicId));
    setPosts((prev) => prev.filter((post) => post.topic_id !== topicId));
    toast.success('Topic supprime.');
    setActionKey(null);
  };

  const deletePost = async (postId: string) => {
    setActionKey(`post:${postId}`);
    const { error } = await supabase.from(FORUM_POSTS_TABLE).delete().eq('id', postId);

    if (error) {
      console.error('Error deleting forum post', error);
      toast.error('Suppression du post impossible.');
      setActionKey(null);
      return;
    }

    setPosts((prev) => prev.filter((post) => post.id !== postId));
    toast.success('Post supprime.');
    setActionKey(null);
  };

  return (
    <div className="space-y-4">
      <Card className="p-4 sm:p-5">
        <div className="flex flex-col lg:flex-row lg:items-end lg:justify-between gap-4">
          <div>
            <h2 className="text-xl font-semibold text-white">Forum Moderation</h2>
            <p className="text-zinc-400 text-sm mt-1">
              Moderation simple des topics et posts forum.
            </p>
          </div>
          <Button variant="outline" onClick={() => void loadForumModeration()}>
            Actualiser
          </Button>
        </div>
      </Card>

      <Card className="p-4 sm:p-5">
        <h3 className="text-lg font-semibold text-white mb-4">Derniers topics</h3>
        {isLoading ? (
          <p className="text-zinc-400">Chargement...</p>
        ) : topics.length === 0 ? (
          <p className="text-zinc-500">Aucun topic.</p>
        ) : (
          <div className="space-y-3">
            {topics.map((topic) => {
              const category = categoryMap.get(topic.category_id);
              return (
                <div key={topic.id} className="rounded-lg border border-zinc-800 bg-zinc-950/60 p-4">
                  <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div className="space-y-1">
                      <p className="text-sm text-zinc-500">
                        {category?.name || topic.category_id} • {new Date(topic.created_at).toLocaleString('fr-FR')}
                      </p>
                      <h4 className="text-white font-medium">{topic.title}</h4>
                      <p className="text-xs text-zinc-500">{topic.slug}</p>
                    </div>
                    <Button
                      variant="danger"
                      size="sm"
                      isLoading={actionKey === `topic:${topic.id}`}
                      onClick={() => void deleteTopic(topic.id)}
                    >
                      Supprimer
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </Card>

      <Card className="p-4 sm:p-5">
        <h3 className="text-lg font-semibold text-white mb-4">Derniers posts</h3>
        {isLoading ? (
          <p className="text-zinc-400">Chargement...</p>
        ) : posts.length === 0 ? (
          <p className="text-zinc-500">Aucun post.</p>
        ) : (
          <div className="space-y-3">
            {posts.map((post) => {
              const topic = topicMap.get(post.topic_id);
              const preview = post.content.length > 180 ? `${post.content.slice(0, 180).trim()}...` : post.content;

              return (
                <div key={post.id} className="rounded-lg border border-zinc-800 bg-zinc-950/60 p-4">
                  <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <div className="space-y-1">
                      <p className="text-sm text-zinc-500">
                        {topic?.title || post.topic_id} • {new Date(post.created_at).toLocaleString('fr-FR')}
                      </p>
                      <p className="text-sm text-zinc-200 whitespace-pre-wrap">{preview}</p>
                    </div>
                    <Button
                      variant="danger"
                      size="sm"
                      isLoading={actionKey === `post:${post.id}`}
                      onClick={() => void deletePost(post.id)}
                    >
                      Supprimer
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </Card>
    </div>
  );
}
