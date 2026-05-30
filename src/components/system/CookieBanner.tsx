import { useCookieConsent } from '../../hooks/useCookieConsent';

export function CookieBanner() {
  const { consentStatus, acceptCookies, rejectCookies } = useCookieConsent();

  if (consentStatus !== 'unknown') {
    return null;
  }

  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-0 z-[100] px-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] sm:px-6 sm:pb-6">
      <div className="pointer-events-auto mx-auto w-full max-w-[calc(100vw-1.5rem)] rounded-xl border border-zinc-800 bg-zinc-950/95 p-3 text-white shadow-2xl shadow-black/40 backdrop-blur animate-[cookie-banner-in_220ms_ease-out] sm:max-w-3xl sm:rounded-2xl sm:p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div className="min-w-0">
            <p className="text-sm font-semibold text-white">Cookies</p>
            <p className="mt-1 text-sm leading-5 text-zinc-300 sm:leading-6">
              Nous utilisons des cookies pour améliorer votre expérience.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-2 sm:flex sm:items-center">
            <button
              type="button"
              onClick={rejectCookies}
              className="inline-flex h-10 items-center justify-center rounded-lg border border-zinc-700 px-4 text-sm font-medium text-zinc-300 transition hover:border-zinc-600 hover:bg-zinc-900 hover:text-white"
            >
              Refuser
            </button>
            <button
              type="button"
              onClick={acceptCookies}
              className="inline-flex h-10 items-center justify-center rounded-lg bg-gradient-to-r from-rose-500 to-orange-500 px-4 text-sm font-medium text-white transition hover:from-rose-600 hover:to-orange-600"
            >
              Accepter
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
