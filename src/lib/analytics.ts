const MEASUREMENT_ID = (import.meta.env.VITE_GA_MEASUREMENT_ID as string | undefined)?.trim() ?? '';
const ALLOWED_HOSTNAMES = new Set(['beatelion.com', 'www.beatelion.com']);
const ANALYTICS_CONSENT_KEY = 'beatelion_analytics_consent';

type GtagParams = Record<string, string | number | boolean | null | undefined>;
type GtagCommand = 'js' | 'config' | 'event' | 'consent';

declare global {
  interface Window {
    dataLayer?: unknown[];
    gtag?: (command: GtagCommand, target: string | Date, params?: GtagParams) => void;
  }
}

let analyticsInitialized = false;
let analyticsInitPromise: Promise<void> | null = null;

function hasAnalyticsConsent() {
  try {
    return window.localStorage.getItem(ANALYTICS_CONSENT_KEY) === 'granted';
  } catch {
    return false;
  }
}

function canRunAnalytics() {
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return false;
  }

  if (!import.meta.env.PROD || !MEASUREMENT_ID) {
    return false;
  }

  return ALLOWED_HOSTNAMES.has(window.location.hostname) && hasAnalyticsConsent();
}

function ensureGtagRuntime() {
  window.dataLayer = window.dataLayer ?? [];

  if (typeof window.gtag !== 'function') {
    window.gtag = function gtag(...args: unknown[]) {
      window.dataLayer?.push(args);
    };
  }
}

function loadGtagScript() {
  const existingScript = document.querySelector<HTMLScriptElement>(
    `script[data-ga-measurement-id="${MEASUREMENT_ID}"]`,
  );

  if (existingScript) {
    return Promise.resolve();
  }

  return new Promise<void>((resolve, reject) => {
    const script = document.createElement('script');
    script.async = true;
    script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(MEASUREMENT_ID)}`;
    script.dataset.gaMeasurementId = MEASUREMENT_ID;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('Failed to load Google Analytics script'));
    document.head.appendChild(script);
  });
}

async function withAnalyticsReady(callback: () => void) {
  await initAnalytics();

  if (!analyticsInitialized || typeof window.gtag !== 'function') {
    return;
  }

  callback();
}

export async function initAnalytics() {
  if (!canRunAnalytics()) {
    return;
  }

  if (analyticsInitialized) {
    return;
  }

  if (!analyticsInitPromise) {
    analyticsInitPromise = loadGtagScript()
      .then(() => {
        ensureGtagRuntime();
        window.gtag?.('js', new Date());
        window.gtag?.('config', MEASUREMENT_ID, {
          send_page_view: false,
          anonymize_ip: true,
        });
        analyticsInitialized = true;
      })
      .catch(() => {
        analyticsInitialized = false;
      })
      .finally(() => {
        analyticsInitPromise = null;
      });
  }

  await analyticsInitPromise;
}

export function trackPage(path: string) {
  void withAnalyticsReady(() => {
    window.gtag?.('event', 'page_view', {
      page_path: path,
      page_location: `${window.location.origin}${path}`,
      page_title: document.title,
    });
  });
}

export function trackEvent(name: string, params: GtagParams = {}) {
  void withAnalyticsReady(() => {
    window.gtag?.('event', name, params);
  });
}

export function useAnalytics() {
  return {
    initAnalytics,
    trackEvent,
    trackPage,
  };
}
