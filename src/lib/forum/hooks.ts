import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../supabase/client';
import type { ForumAuthor, ForumCategory, ForumPost, ForumTopic, LatestForumTopic, UserProfile } from '../supabase/types';
import { fetchPublicProducerProfilesMap } from '../supabase/publicProfiles';
import { slugify } from '../utils/format';
import { useAuth } from '../auth/hooks';

const FORUM_CATEGORIES_TABLE = 'forum_categories' as any;
const FORUM_TOPICS_TABLE = 'forum_topics' as any;
const FORUM_POSTS_TABLE = 'forum_posts' as any;

type ForumCategoryRow = Omit<ForumCategory, 'topic_count' | 'post_count'>;
type ForumTopicRow = Omit<ForumTopic, 'author'>;
type ForumPostRow = Omit<ForumPost, 'author'>;

const getFallbackAuthor = (userId: string, profile: UserProfile | null | undefined): ForumAuthor | undefined => {
  if (!profile || profile.id !== userId) return undefined;
  return {
    id: profile.id,
    username: profile.username || profile.full_name || profile.email,
    avatar_url: profile.avatar_url,
  };
};

const attachAuthorsToTopics = async (
  rows: ForumTopicRow[],
  profile: UserProfile | null | undefined,
): Promise<ForumTopic[]> => {
  const producerMap = await fetchPublicProducerProfilesMap(rows.map((row) => row.user_id));

  return rows.map((row) => {
    const producer = producerMap.get(row.user_id);
    const fallback = getFallbackAuthor(row.user_id, profile);

    return {
      ...row,
      author: producer
        ? {
            id: producer.user_id,
            username: producer.username,
            avatar_url: producer.avatar_url,
          }
        : fallback,
    };
  });
};

const attachAuthorsToPosts = async (
  rows: ForumPostRow[],
  profile: UserProfile | null | undefined,
): Promise<ForumPost[]> => {
  const producerMap = await fetchPublicProducerProfilesMap(rows.map((row) => row.user_id));

  return rows.map((row) => {
    const producer = producerMap.get(row.user_id);
    const fallback = getFallbackAuthor(row.user_id, profile);

    return {
      ...row,
      author: producer
        ? {
            id: producer.user_id,
            username: producer.username,
            avatar_url: producer.avatar_url,
          }
        : fallback,
    };
  });
};

export function useForumCategories() {
  const [categories, setCategories] = useState<ForumCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const [{ data: categoriesData, error: categoriesError }, { data: topicsData, error: topicsError }] =
        await Promise.all([
          supabase.from(FORUM_CATEGORIES_TABLE).select('*').order('position', { ascending: true }).order('created_at', { ascending: true }),
          supabase.from(FORUM_TOPICS_TABLE).select('id, category_id, post_count'),
        ]);

      if (categoriesError) throw categoriesError;
      if (topicsError) throw topicsError;

      const categoryRows = ((categoriesData as unknown as ForumCategoryRow[] | null) ?? []);
      const topicRows = ((topicsData as unknown as Array<Pick<ForumTopicRow, 'id' | 'category_id' | 'post_count'>> | null) ?? []);

      const countsByCategory = new Map<string, { topicCount: number; postCount: number }>();

      for (const topic of topicRows) {
        const current = countsByCategory.get(topic.category_id) ?? { topicCount: 0, postCount: 0 };
        current.topicCount += 1;
        current.postCount += topic.post_count ?? 0;
        countsByCategory.set(topic.category_id, current);
      }

      setCategories(
        categoryRows.map((category) => {
          const counts = countsByCategory.get(category.id);
          return {
            ...category,
            topic_count: counts?.topicCount ?? 0,
            post_count: counts?.postCount ?? 0,
          };
        }),
      );
    } catch (loadError) {
      console.error('Failed to load forum categories', loadError);
      setError('Impossible de charger les categories du forum.');
      setCategories([]);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { categories, isLoading, error, refresh };
}

export function useLatestForumTopics(limit = 8) {
  const { profile } = useAuth();
  const [topics, setTopics] = useState<LatestForumTopic[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const [{ data: categoriesData, error: categoriesError }, { data: topicsData, error: topicsError }] =
        await Promise.all([
          supabase.from(FORUM_CATEGORIES_TABLE).select('*'),
          supabase.from(FORUM_TOPICS_TABLE).select('*').order('last_post_at', { ascending: false }).limit(limit),
        ]);

      if (categoriesError) throw categoriesError;
      if (topicsError) throw topicsError;

      const categoryRows = ((categoriesData as unknown as ForumCategoryRow[] | null) ?? []);
      const topicRows = ((topicsData as unknown as ForumTopicRow[] | null) ?? []);
      const categoriesById = new Map(categoryRows.map((category) => [category.id, category]));
      const topicsWithAuthors = await attachAuthorsToTopics(topicRows, profile);

      setTopics(
        topicsWithAuthors
          .map((topic) => {
            const category = categoriesById.get(topic.category_id);

            return {
              ...topic,
              category_name: category?.name ?? 'Categorie inconnue',
              category_slug: category?.slug ?? '',
              category_is_premium_only: category?.is_premium_only ?? false,
            };
          })
          .filter((topic) => topic.category_slug.length > 0),
      );
    } catch (loadError) {
      console.error('Failed to load latest forum topics', loadError);
      setTopics([]);
      setError('Impossible de charger les derniers topics.');
    } finally {
      setIsLoading(false);
    }
  }, [limit, profile]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { topics, isLoading, error, refresh };
}

interface UseForumTopicsOptions {
  categorySlug?: string;
  page: number;
  pageSize?: number;
}

export function useForumTopics({ categorySlug, page, pageSize = 20 }: UseForumTopicsOptions) {
  const { profile } = useAuth();
  const [category, setCategory] = useState<ForumCategoryRow | null>(null);
  const [topics, setTopics] = useState<ForumTopic[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const totalPages = useMemo(
    () => Math.max(1, Math.ceil(totalCount / pageSize)),
    [pageSize, totalCount],
  );

  const refresh = useCallback(async () => {
    if (!categorySlug) {
      setCategory(null);
      setTopics([]);
      setTotalCount(0);
      setIsLoading(false);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const { data: categoryData, error: categoryError } = await supabase
        .from(FORUM_CATEGORIES_TABLE)
        .select('*')
        .eq('slug', categorySlug)
        .maybeSingle();

      if (categoryError) throw categoryError;

      const categoryRow = (categoryData as unknown as ForumCategoryRow | null) ?? null;
      if (!categoryRow) {
        setCategory(null);
        setTopics([]);
        setTotalCount(0);
        setError('Categorie introuvable ou reservee.');
        return;
      }

      setCategory(categoryRow);

      const from = Math.max(0, (page - 1) * pageSize);
      const to = from + pageSize - 1;

      const { data: topicData, error: topicError, count } = await supabase
        .from(FORUM_TOPICS_TABLE)
        .select('*', { count: 'exact' })
        .eq('category_id', categoryRow.id)
        .order('is_pinned', { ascending: false })
        .order('last_post_at', { ascending: false })
        .range(from, to);

      if (topicError) throw topicError;

      const topicRows = ((topicData as unknown as ForumTopicRow[] | null) ?? []);
      setTopics(await attachAuthorsToTopics(topicRows, profile));
      setTotalCount(count ?? 0);
    } catch (loadError) {
      console.error('Failed to load forum topics', loadError);
      setCategory(null);
      setTopics([]);
      setTotalCount(0);
      setError('Impossible de charger cette categorie.');
    } finally {
      setIsLoading(false);
    }
  }, [categorySlug, page, pageSize, profile]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { category, topics, totalCount, totalPages, isLoading, error, refresh };
}

interface UseForumPostsOptions {
  categorySlug?: string;
  topicSlug?: string;
  page: number;
  pageSize?: number;
}

export function useForumPosts({ categorySlug, topicSlug, page, pageSize = 20 }: UseForumPostsOptions) {
  const { profile } = useAuth();
  const [category, setCategory] = useState<ForumCategoryRow | null>(null);
  const [topic, setTopic] = useState<ForumTopic | null>(null);
  const [posts, setPosts] = useState<ForumPost[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const totalPages = useMemo(
    () => Math.max(1, Math.ceil(totalCount / pageSize)),
    [pageSize, totalCount],
  );

  const refresh = useCallback(async () => {
    if (!categorySlug || !topicSlug) {
      setCategory(null);
      setTopic(null);
      setPosts([]);
      setTotalCount(0);
      setIsLoading(false);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const { data: categoryData, error: categoryError } = await supabase
        .from(FORUM_CATEGORIES_TABLE)
        .select('*')
        .eq('slug', categorySlug)
        .maybeSingle();

      if (categoryError) throw categoryError;

      const categoryRow = (categoryData as unknown as ForumCategoryRow | null) ?? null;
      if (!categoryRow) {
        setCategory(null);
        setTopic(null);
        setPosts([]);
        setTotalCount(0);
        setError('Topic introuvable ou reserve.');
        return;
      }

      setCategory(categoryRow);

      const { data: topicData, error: topicError } = await supabase
        .from(FORUM_TOPICS_TABLE)
        .select('*')
        .eq('category_id', categoryRow.id)
        .eq('slug', topicSlug)
        .maybeSingle();

      if (topicError) throw topicError;

      const topicRow = (topicData as unknown as ForumTopicRow | null) ?? null;
      if (!topicRow) {
        setTopic(null);
        setPosts([]);
        setTotalCount(0);
        setError('Topic introuvable ou reserve.');
        return;
      }

      const [topicWithAuthor] = await attachAuthorsToTopics([topicRow], profile);
      setTopic(topicWithAuthor ?? null);

      const from = Math.max(0, (page - 1) * pageSize);
      const to = from + pageSize - 1;

      const { data: postData, error: postError, count } = await supabase
        .from(FORUM_POSTS_TABLE)
        .select('*', { count: 'exact' })
        .eq('topic_id', topicRow.id)
        .order('created_at', { ascending: true })
        .range(from, to);

      if (postError) throw postError;

      const postRows = ((postData as unknown as ForumPostRow[] | null) ?? []);
      setPosts(await attachAuthorsToPosts(postRows, profile));
      setTotalCount(count ?? 0);
    } catch (loadError) {
      console.error('Failed to load forum topic', loadError);
      setCategory(null);
      setTopic(null);
      setPosts([]);
      setTotalCount(0);
      setError('Impossible de charger ce topic.');
    } finally {
      setIsLoading(false);
    }
  }, [categorySlug, topicSlug, page, pageSize, profile]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { category, topic, posts, totalCount, totalPages, isLoading, error, refresh };
}

export function useForumActions() {
  const { user } = useAuth();
  const [isSubmitting, setIsSubmitting] = useState(false);

  const createTopic = useCallback(async (input: { categoryId: string; title: string; content: string }) => {
    if (!user) {
      throw new Error('Vous devez etre connecte pour creer un topic.');
    }

    setIsSubmitting(true);

    const slugBase = slugify(input.title.trim()) || 'topic';
    const topicSlug = `${slugBase}-${crypto.randomUUID().slice(0, 8)}`;

    try {
      const { data: topicData, error: topicError } = await supabase
        .from(FORUM_TOPICS_TABLE)
        .insert({
          category_id: input.categoryId,
          user_id: user.id,
          title: input.title.trim(),
          slug: topicSlug,
        })
        .select('*')
        .single();

      if (topicError) throw topicError;

      const topic = topicData as unknown as ForumTopicRow;

      const { error: postError } = await supabase
        .from(FORUM_POSTS_TABLE)
        .insert({
          topic_id: topic.id,
          user_id: user.id,
          content: input.content.trim(),
        });

      if (postError) {
        const { error: cleanupError } = await supabase
          .from(FORUM_TOPICS_TABLE)
          .delete()
          .eq('id', topic.id)
          .eq('user_id', user.id);

        if (cleanupError) {
          console.error('Failed to rollback forum topic creation', cleanupError);
        }

        throw postError;
      }

      return topic;
    } finally {
      setIsSubmitting(false);
    }
  }, [user]);

  const createReply = useCallback(async (input: { topicId: string; content: string }) => {
    if (!user) {
      throw new Error('Vous devez etre connecte pour repondre.');
    }

    setIsSubmitting(true);

    try {
      const { data, error } = await supabase
        .from(FORUM_POSTS_TABLE)
        .insert({
          topic_id: input.topicId,
          user_id: user.id,
          content: input.content.trim(),
        })
        .select('*')
        .single();

      if (error) throw error;
      return data as unknown as ForumPostRow;
    } finally {
      setIsSubmitting(false);
    }
  }, [user]);

  return { createTopic, createReply, isSubmitting };
}
