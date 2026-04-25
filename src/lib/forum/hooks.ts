import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '@/lib/supabase/client';
import type { ForumAuthor, ForumCategory, ForumPost, ForumPostAttachment, ForumTopic, LatestForumTopic, UserProfile } from '../supabase/types';
import { fetchForumPublicProfilesMap } from '../supabase/forumProfiles';
import { useAuth } from '../auth/hooks';
import { useTranslation, type TranslateFn } from '../i18n';

const FORUM_CATEGORIES_TABLE = 'forum_categories';
const FORUM_TOPICS_TABLE = 'forum_topics';
const FORUM_POSTS_TABLE = 'forum_posts';
const FORUM_POST_ATTACHMENTS_TABLE = 'forum_post_attachments';
const FORUM_MEDIA_BUCKET = 'forum-media';
const FORUM_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
const FORUM_VIDEO_MAX_BYTES = 50 * 1024 * 1024;
const FORUM_IMAGE_MIME_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/gif']);
const FORUM_VIDEO_MIME_TYPES = new Set(['video/mp4', 'video/webm', 'video/quicktime']);

type ForumCategoryRow = Omit<ForumCategory, 'topic_count' | 'post_count'>;
type ForumTopicRow = Omit<ForumTopic, 'author'>;
type ForumPostRow = Omit<ForumPost, 'author'>;
type ForumPostAttachmentRow = Omit<ForumPostAttachment, 'signed_url'>;
type ForumMutationStatus = 'allowed' | 'review';

type PendingForumMediaPayload = {
  path: string;
  media_type: 'image' | 'video';
  mime_type: string;
  file_size: number;
  original_filename: string;
};

type ForumCreateTopicResult = {
  ok: boolean;
  status: ForumMutationStatus;
  topic_id: string;
  topic_slug: string;
  category_slug: string;
  post_id: string;
  attachment?: ForumPostAttachmentRow | null;
  moderation_score?: number | null;
  moderation_reason?: string | null;
};

type ForumCreatePostResult = {
  ok: boolean;
  status: ForumMutationStatus;
  post_id: string;
  topic_id: string;
  topic_slug?: string | null;
  category_slug?: string | null;
  attachment?: ForumPostAttachmentRow | null;
  moderation_score?: number | null;
  moderation_reason?: string | null;
};

type ForumFunctionError = Error & {
  code?: string;
  status?: number;
};

const getFallbackAuthor = (userId: string, profile: UserProfile | null | undefined): ForumAuthor | undefined => {
  if (!profile || profile.id !== userId) return undefined;
  return {
    id: profile.id,
    username: profile.username || profile.full_name || profile.email,
    avatar_url: profile.avatar_url,
  };
};

const loadForumProfilesMap = async (userIds: string[]) => {
  try {
    return await fetchForumPublicProfilesMap(userIds);
  } catch (error) {
    console.warn('Forum public profiles unavailable, using fallback author labels', error);
    return new Map();
  }
};

const attachAuthorsToTopics = async (
  rows: ForumTopicRow[],
  profile: UserProfile | null | undefined,
): Promise<ForumTopic[]> => {
  const producerMap = await loadForumProfilesMap(rows.map((row) => row.user_id));

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
            rank_tier: producer.rank,
            reputation_score: producer.reputation,
          }
        : fallback,
    };
  });
};

const readFunctionError = async (error: unknown, fallbackMessage: string): Promise<ForumFunctionError> => {
  const enriched = new Error(fallbackMessage) as ForumFunctionError;

  if (!(error instanceof Error)) {
    return enriched;
  }

  enriched.name = error.name;
  const maybeError = error as Error & { context?: Response };
  const response = maybeError.context;

  if (response instanceof Response) {
    enriched.status = response.status;
    try {
      const payload = await response.json() as { error?: string; code?: string };
      enriched.message = payload.error || fallbackMessage;
      enriched.code = payload.code;
      return enriched;
    } catch {
      enriched.message = fallbackMessage;
      return enriched;
    }
  }

  enriched.message = error.message || fallbackMessage;
  return enriched;
};

const invokeForumFunction = async <T,>(
  functionName: string,
  body: Record<string, unknown>,
  fallbackMessage: string,
  sessionExpiredMessage: string,
): Promise<T> => {
  // Get session and Authorization header
  const { data: { session } } = await supabase.auth.getSession();

  if (!session?.access_token) {
    throw new Error('User is not authenticated.');
  }

  const { data, error } = await supabase.functions.invoke<T>(functionName, {
    headers: {
      Authorization: `Bearer ${session.access_token}`,
    },
    body,
  });

  if (error) {
    const parsedError = await readFunctionError(error, fallbackMessage);
    if (parsedError.status === 401) {
      throw new Error(sessionExpiredMessage);
    }
    throw parsedError;
  }

  return data as T;
};

export const isForumFunctionError = (error: unknown): error is ForumFunctionError => {
  return error instanceof Error;
};

export const getForumFunctionErrorCode = (error: unknown) => {
  return isForumFunctionError(error) ? error.code ?? null : null;
};

export const getForumFunctionErrorMessage = (error: unknown, fallbackMessage: string) => {
  return isForumFunctionError(error) ? error.message || fallbackMessage : fallbackMessage;
};

const attachAuthorsToPosts = async (
  rows: ForumPostRow[],
  profile: UserProfile | null | undefined,
): Promise<ForumPost[]> => {
  const producerMap = await loadForumProfilesMap(rows.map((row) => row.user_id));

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
            rank_tier: producer.rank,
            reputation_score: producer.reputation,
          }
        : row.is_ai_generated && row.ai_agent_name
        ? {
            id: row.user_id,
            username: row.ai_agent_name,
            avatar_url: null,
          }
        : fallback,
    };
  });
};

const getForumMediaType = (file: File): 'image' | 'video' | null => {
  if (file.type.startsWith('image/')) return 'image';
  if (file.type.startsWith('video/')) return 'video';
  return null;
};

const sanitizeForumFilename = (name: string) => {
  const cleaned = name
    .normalize('NFKD')
    .replace(/[^\w.-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 100);

  return cleaned || 'forum-media';
};

const uploadPendingForumMedia = async (
  file: File,
  userId: string,
  t: TranslateFn,
): Promise<PendingForumMediaPayload> => {
  const mediaType = getForumMediaType(file);
  if (!mediaType) {
    throw new Error(t('forum.mediaInvalidType'));
  }

  const allowedMime = mediaType === 'image'
    ? FORUM_IMAGE_MIME_TYPES.has(file.type)
    : FORUM_VIDEO_MIME_TYPES.has(file.type);

  if (!allowedMime) {
    throw new Error(t('forum.mediaInvalidType'));
  }

  const maxBytes = mediaType === 'image' ? FORUM_IMAGE_MAX_BYTES : FORUM_VIDEO_MAX_BYTES;
  if (file.size <= 0 || file.size > maxBytes) {
    throw new Error(t('forum.mediaTooLarge', {
      size: mediaType === 'image' ? '5 MB' : '50 MB',
    }));
  }

  const safeName = sanitizeForumFilename(file.name);
  const path = `pending/${userId}/${crypto.randomUUID()}-${safeName}`;
  const { error } = await supabase.storage.from(FORUM_MEDIA_BUCKET).upload(path, file, {
    cacheControl: '3600',
    contentType: file.type,
    upsert: false,
  });

  if (error) {
    throw new Error(t('forum.mediaUploadError'));
  }

  return {
    path,
    media_type: mediaType,
    mime_type: file.type,
    file_size: file.size,
    original_filename: safeName,
  };
};

const removePendingForumMedia = async (path: string | null) => {
  if (!path) return;
  await supabase.storage.from(FORUM_MEDIA_BUCKET).remove([path]);
};

const attachMediaToPosts = async (posts: ForumPost[]): Promise<ForumPost[]> => {
  const postIds = posts.map((post) => post.id);
  if (postIds.length === 0) return posts;

  const { data, error } = await supabase
    .from(FORUM_POST_ATTACHMENTS_TABLE)
    .select('*')
    .in('post_id', postIds)
    .order('created_at', { ascending: true });

  if (error) {
    console.warn('Failed to load forum post attachments', error);
    return posts;
  }

  const rows = ((data as unknown as ForumPostAttachmentRow[] | null) ?? []);
  const signedRows = await Promise.all(rows.map(async (attachment) => {
    const { data: signedData, error: signedError } = await supabase.storage
      .from(attachment.bucket || FORUM_MEDIA_BUCKET)
      .createSignedUrl(attachment.storage_path, 60 * 60);

    if (signedError) {
      console.warn('Failed to sign forum media URL', signedError);
      return { ...attachment, signed_url: null };
    }

    return { ...attachment, signed_url: signedData?.signedUrl ?? null };
  }));

  const attachmentsByPost = new Map<string, ForumPostAttachment[]>();
  for (const attachment of signedRows) {
    const bucket = attachmentsByPost.get(attachment.post_id) ?? [];
    bucket.push(attachment);
    attachmentsByPost.set(attachment.post_id, bucket);
  }

  return posts.map((post) => ({
    ...post,
    attachments: attachmentsByPost.get(post.id) ?? [],
  }));
};

export function useForumCategories() {
  const { t } = useTranslation();
  const [categories, setCategories] = useState<ForumCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const { data, error: rpcError } = await supabase.rpc('get_forum_categories_with_stats');

      if (rpcError) throw rpcError;

      const rows = ((data as unknown as ForumCategory[] | null) ?? []);
      setCategories(rows);
    } catch (loadError) {
      console.error('Failed to load forum categories', loadError);
      setError(t('forum.categoriesLoadError'));
      setCategories([]);
    } finally {
      setIsLoading(false);
    }
  }, [t]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { categories, isLoading, error, refresh };
}

export function useLatestForumTopics(limit = 8) {
  const { profile } = useAuth();
  const { t } = useTranslation();
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
              category_name: category?.name ?? t('forum.unknownCategory'),
              category_slug: category?.slug ?? '',
              category_is_premium_only: category?.is_premium_only ?? false,
            };
          })
          .filter((topic) => topic.category_slug.length > 0),
      );
    } catch (loadError) {
      console.error('Failed to load latest forum topics', loadError);
      setTopics([]);
      setError(t('forum.latestTopicsLoadError'));
    } finally {
      setIsLoading(false);
    }
  }, [limit, profile, t]);

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
  const { t } = useTranslation();
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
        setError(t('forum.categoryUnavailable'));
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
      setError(t('forum.categoryLoadError'));
    } finally {
      setIsLoading(false);
    }
  }, [categorySlug, page, pageSize, profile, t]);

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
  const { t } = useTranslation();
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
        setError(t('forum.topicUnavailable'));
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
        setError(t('forum.topicUnavailable'));
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
      const postsWithAuthors = await attachAuthorsToPosts(postRows, profile);
      setPosts(await attachMediaToPosts(postsWithAuthors));
      setTotalCount(count ?? 0);
    } catch (loadError) {
      console.error('Failed to load forum topic', loadError);
      setCategory(null);
      setTopic(null);
      setPosts([]);
      setTotalCount(0);
      setError(t('forum.topicLoadError'));
    } finally {
      setIsLoading(false);
    }
  }, [categorySlug, topicSlug, page, pageSize, profile, t]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return { category, topic, posts, totalCount, totalPages, isLoading, error, refresh };
}

export function useForumActions() {
  const { user } = useAuth();
  const { t } = useTranslation();
  const [isSubmitting, setIsSubmitting] = useState(false);

  const createTopic = useCallback(async (input: { categorySlug: string; title: string; content: string; mediaFile?: File | null }) => {
    if (!user) {
      throw new Error(t('forum.loginRequiredCreateTopic'));
    }

    setIsSubmitting(true);
    let pendingMediaPath: string | null = null;

    try {
      const media = input.mediaFile
        ? await uploadPendingForumMedia(input.mediaFile, user.id, t)
        : null;
      pendingMediaPath = media?.path ?? null;

      return await invokeForumFunction<ForumCreateTopicResult>(
        'forum-create-topic',
        {
          category_slug: input.categorySlug,
          title: input.title.trim(),
          content: input.content.trim(),
          media,
        },
        t('forum.createTopicError'),
        t('forum.sessionExpired'),
      );
    } catch (error) {
      await removePendingForumMedia(pendingMediaPath);
      throw error;
    } finally {
      setIsSubmitting(false);
    }
  }, [t, user]);

  const createReply = useCallback(async (input: { topicId: string; content: string; mediaFile?: File | null }) => {
    if (!user) {
      throw new Error(t('forum.loginRequiredReply'));
    }

    setIsSubmitting(true);
    let pendingMediaPath: string | null = null;

    try {
      const media = input.mediaFile
        ? await uploadPendingForumMedia(input.mediaFile, user.id, t)
        : null;
      pendingMediaPath = media?.path ?? null;

      return await invokeForumFunction<ForumCreatePostResult>(
        'forum-create-post',
        {
          topic_id: input.topicId,
          content: input.content.trim(),
          media,
        },
        t('forum.publishReplyError'),
        t('forum.sessionExpired'),
      );
    } catch (error) {
      await removePendingForumMedia(pendingMediaPath);
      throw error;
    } finally {
      setIsSubmitting(false);
    }
  }, [t, user]);

  const likePost = useCallback(async (input: { postId: string }) => {
    if (!user) {
      throw new Error(t('forum.loginRequiredReply'));
    }

    const postId = input.postId.trim();
    if (!postId) {
      throw new Error('post_id_required');
    }

    const { error } = await supabase.rpc('rpc_like_forum_post', {
      p_post_id: postId,
    });

    if (error) {
      throw error;
    }
  }, [t, user]);

  return { createTopic, createReply, likePost, isSubmitting };
}
