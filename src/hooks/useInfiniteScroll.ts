import { useEffect, useRef } from 'react';

interface UseInfiniteScrollOptions {
  isEnabled: boolean;
  isLoading?: boolean;
  rootMargin?: string;
  onLoadMore: () => void;
}

export function useInfiniteScroll({
  isEnabled,
  isLoading = false,
  rootMargin = '360px 0px',
  onLoadMore,
}: UseInfiniteScrollOptions) {
  const sentinelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel || !isEnabled) return;

    const observer = new IntersectionObserver(([entry]) => {
      if (entry?.isIntersecting && !isLoading) {
        onLoadMore();
      }
    }, { rootMargin });

    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [isEnabled, isLoading, onLoadMore, rootMargin]);

  return sentinelRef;
}
