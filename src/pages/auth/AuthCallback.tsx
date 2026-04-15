import { useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Music } from 'lucide-react';
import { useAuth } from '../../lib/auth/hooks';

/**
 * OAuth callback landing page.
 *
 * When Supabase redirects back from Google (or any OAuth provider), the URL
 * contains ?code=xxx (PKCE flow). The Supabase client detects this via
 * detectSessionInUrl: true and exchanges the code for a session during its own
 * initialization. getSession() (called inside initializeAuth in store.ts) waits
 * for that exchange to complete before resolving, so by the time isInitialized
 * becomes true the user is either authenticated or the exchange failed.
 *
 * This page just shows a loader and redirects once the store is ready.
 * No explicit code exchange needed here.
 */
export function AuthCallback() {
  const { isInitialized, user } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (!isInitialized) return;
    navigate(user ? '/dashboard' : '/login', { replace: true });
  }, [isInitialized, user, navigate]);

  return (
    <div className="min-h-screen bg-zinc-950 flex flex-col items-center justify-center gap-4">
      <div className="w-14 h-14 rounded-2xl bg-gradient-to-br from-rose-500 to-orange-500 flex items-center justify-center animate-pulse">
        <Music className="w-7 h-7 text-white" />
      </div>
      <p className="text-zinc-400 text-sm">Connexion en cours…</p>
    </div>
  );
}
