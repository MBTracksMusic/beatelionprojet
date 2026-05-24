import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import { useTranslation } from '../../lib/i18n';

interface ExpandableTextProps {
  children: ReactNode;
  maxLines?: number;
  className?: string;
}

export function ExpandableText({
  children,
  maxLines = 5,
  className,
}: ExpandableTextProps) {
  const { t } = useTranslation();
  const textRef = useRef<HTMLParagraphElement>(null);
  const [isExpanded, setIsExpanded] = useState(false);
  const [isOverflowing, setIsOverflowing] = useState(false);
  const contentId = useId();

  const measureOverflow = useCallback(() => {
    const el = textRef.current;
    if (!el || isExpanded) return;
    setIsOverflowing(el.scrollHeight > el.clientHeight + 1);
  }, [isExpanded]);

  useLayoutEffect(() => {
    measureOverflow();
  }, [children, maxLines, measureOverflow]);

  useEffect(() => {
    const el = textRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(measureOverflow);
    observer.observe(el);
    return () => observer.disconnect();
  }, [measureOverflow]);

  const clampStyle = !isExpanded
    ? {
        display: '-webkit-box',
        WebkitLineClamp: maxLines,
        WebkitBoxOrient: 'vertical' as const,
        overflow: 'hidden',
      }
    : undefined;

  return (
    <div>
      <p
        ref={textRef}
        id={contentId}
        className={className}
        style={clampStyle}
      >
        {children}
      </p>
      {isOverflowing && (
        <button
          type="button"
          onClick={() => setIsExpanded((v) => !v)}
          aria-expanded={isExpanded}
          aria-controls={contentId}
          className="mt-2 text-sm font-medium text-rose-400 transition-colors hover:text-rose-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-400/40 rounded"
        >
          {isExpanded ? t('common.readLess') : t('common.readMore')}
        </button>
      )}
    </div>
  );
}
