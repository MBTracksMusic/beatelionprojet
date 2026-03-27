import { trackEvent } from '@/lib/analytics';

const PRODUCER_EARNINGS_FALLBACK_SESSION_KEY = 'producer_earnings_fallback_logged';
const PRODUCER_EARNINGS_FALLBACK_EVENT = 'producer_earnings_fallback_used';

let hasTrackedProducerEarningsFallback = false;

type SentryLike = {
  captureMessage?: (...args: unknown[]) => void;
};

type GlobalWindowLike = Window & {
  Sentry?: SentryLike;
};

const getBrowserWindow = (): GlobalWindowLike | null => {
  if (typeof window === 'undefined') {
    return null;
  }

  return window as GlobalWindowLike;
};

const hasTrackedProducerEarningsFallbackInSession = () => {
  const browserWindow = getBrowserWindow();
  if (!browserWindow) {
    return false;
  }

  try {
    return browserWindow.sessionStorage.getItem(PRODUCER_EARNINGS_FALLBACK_SESSION_KEY) === '1';
  } catch {
    return false;
  }
};

const markProducerEarningsFallbackTrackedInSession = () => {
  const browserWindow = getBrowserWindow();
  if (!browserWindow) {
    return;
  }

  try {
    browserWindow.sessionStorage.setItem(PRODUCER_EARNINGS_FALLBACK_SESSION_KEY, '1');
  } catch {
    // Session storage can be unavailable in privacy-restricted contexts.
  }
};

export const isProducerEarningsFallbackForced = () =>
  import.meta.env.DEV && import.meta.env.VITE_FORCE_PRODUCER_EARNINGS_FALLBACK === 'true';

export const trackProducerEarningsFallback = (userId?: string) => {
  if (hasTrackedProducerEarningsFallback || hasTrackedProducerEarningsFallbackInSession()) {
    hasTrackedProducerEarningsFallback = true;
    return;
  }

  hasTrackedProducerEarningsFallback = true;
  markProducerEarningsFallbackTrackedInSession();

  if (import.meta.env.DEV) {
    console.warn('Fallback to raw query: producer_revenue_view missing');
  } else {
    console.error('PROD WARNING: producer_revenue_view missing');
  }

  try {
    trackEvent(PRODUCER_EARNINGS_FALLBACK_EVENT, {
      feature: 'producer_earnings',
      reason: 'producer_revenue_view_missing',
      source: 'fallback',
      user_id: userId ?? null,
      env: import.meta.env.MODE,
    });
  } catch {
    // Analytics is optional for this signal.
  }

  try {
    getBrowserWindow()?.Sentry?.captureMessage?.(PRODUCER_EARNINGS_FALLBACK_EVENT, {
      level: 'warning',
      tags: {
        feature: 'producer_earnings',
        env: import.meta.env.MODE,
      },
      extra: {
        reason: 'producer_revenue_view_missing',
        source: 'fallback',
        user_id: userId ?? null,
      },
    });
  } catch {
    // Sentry is optional for this signal.
  }
};
