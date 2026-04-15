import { useRef, useState } from 'react';
import { Link, useNavigate, useLocation } from 'react-router-dom';
import { Mail, Lock, Music } from 'lucide-react';
import HCaptcha from '@hcaptcha/react-hcaptcha';
import { Button } from '../../components/ui/Button';
import { Input } from '../../components/ui/Input';
import { useTranslation } from '../../lib/i18n';
import { setAnalyticsUserId, trackLogin } from '../../lib/analytics';
import { AuthFunctionError, signIn, loginWithGoogle } from '../../lib/auth/service';
import { supabase } from '@/lib/supabase/client';
import toast from 'react-hot-toast';

export function LoginPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [isGoogleLoading, setIsGoogleLoading] = useState(false);
  const [error, setError] = useState('');

  const captchaSiteKey = (import.meta.env.VITE_HCAPTCHA_SITE_KEY as string | undefined)?.trim() ?? '';
  const isCaptchaConfigured = captchaSiteKey.length > 0;
  const captchaTokenRef = useRef<string | null>(null);
  const [captchaToken, setCaptchaToken] = useState<string | null>(null);
  const [captchaInstanceKey, setCaptchaInstanceKey] = useState(0);

  const resetCaptcha = () => {
    captchaTokenRef.current = null;
    setCaptchaToken(null);
    setCaptchaInstanceKey((current) => current + 1);
  };

  const handleCaptchaVerify = (token: string) => {
    captchaTokenRef.current = token;
    setCaptchaToken(token);
  };

  const handleCaptchaExpire = () => {
    captchaTokenRef.current = null;
    setCaptchaToken(null);
  };

  const handleCaptchaError = () => {
    captchaTokenRef.current = null;
    setCaptchaToken(null);
    toast.error(t('auth.captchaUnavailable'));
  };

  const from = (location.state as { from?: { pathname: string } } | null)?.from?.pathname || '/';

  const handleGoogleLogin = async () => {
    setIsGoogleLoading(true);
    try {
      await loginWithGoogle();
      // loginWithGoogle() triggers a browser redirect — code below won't run
    } catch {
      toast.error(t('errors.generic'));
      setIsGoogleLoading(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (!isCaptchaConfigured) {
      toast.error(t('auth.captchaUnavailable'));
      return;
    }
    if (!captchaTokenRef.current) {
      toast.error(t('auth.captchaRequired'));
      return;
    }

    setIsLoading(true);

    try {
      const result = await signIn({ email, password, captchaToken: captchaTokenRef.current });

      if (result.user && !result.user.email_confirmed_at) {
        navigate(`/email-confirmation?email=${encodeURIComponent(email)}`);
        toast.error(t('auth.confirmEmailBeforeLogin'));
        return;
      }

      if (!result.session) {
        console.warn('Login completed without session payload, redirect aborted');
        setError(t('auth.invalidCredentials'));
        return;
      }

      if (result.user?.id) {
        setAnalyticsUserId(result.user.id);
      }
      trackLogin('email');
      toast.success(t('auth.loginSuccess'));
      if (from !== '/' && from !== '/login') {
        navigate(from, { replace: true });
        return;
      }

      let destination = '/dashboard';

      if (result.user?.id) {
        const { data: profileData, error: profileError } = await supabase
          .from('user_profiles')
          .select('role')
          .eq('id', result.user.id)
          .maybeSingle();

        if (profileError) {
          console.error('Error loading profile role after login:', profileError);
        } else {
          const role = (profileData as { role?: string | null } | null)?.role;
          if (role === 'admin') {
            destination = '/admin';
          }
        }
      }

      navigate(destination, { replace: true });
    } catch (error) {
      console.error('Login error:', error);
      const authError = error as AuthFunctionError;
      const normalizedMessage = authError.message?.toLowerCase() ?? '';

      if (
        authError instanceof AuthFunctionError
        && (
          authError.code === 'email_not_confirmed'
          || normalizedMessage.includes('email not confirmed')
        )
      ) {
        navigate(`/email-confirmation?email=${encodeURIComponent(email.trim())}`);
        toast.error(t('auth.confirmEmailBeforeLogin'));
        return;
      }

      setError(t('auth.invalidCredentials'));
    } finally {
      resetCaptcha();
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center px-4 py-12 bg-zinc-950">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <Link to="/" className="inline-flex items-center gap-2 mb-6">
            <div className="w-12 h-12 rounded-xl bg-gradient-to-br from-rose-500 to-orange-500 flex items-center justify-center">
              <Music className="w-6 h-6 text-white" />
            </div>
          </Link>
          <h1 className="text-2xl font-bold text-white mb-2">
            {t('auth.loginTitle')}
          </h1>
          <p className="text-zinc-400">
            {t('auth.noAccount')}{' '}
            <Link to="/register" className="text-rose-400 hover:text-rose-300">
              {t('auth.registerButton')}
            </Link>
          </p>
        </div>

        <div className="bg-zinc-900 rounded-2xl p-8 border border-zinc-800">
          <form onSubmit={handleSubmit} className="space-y-5">
            {error && (
              <div className="p-3 bg-red-900/20 border border-red-800 rounded-lg text-red-400 text-sm">
                {error}
              </div>
            )}

            <Input
              type="email"
              label={t('auth.email')}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              leftIcon={<Mail className="w-5 h-5" />}
              placeholder={t('auth.emailPlaceholder')}
              required
              autoComplete="email"
            />

            <Input
              type="password"
              label={t('auth.password')}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              leftIcon={<Lock className="w-5 h-5" />}
              placeholder={t('auth.passwordPlaceholder')}
              required
              autoComplete="current-password"
            />

            <div className="flex items-center justify-end">
              <Link
                to="/forgot-password"
                className="text-sm text-zinc-400 hover:text-rose-400 transition-colors"
              >
                {t('auth.forgotPassword')}
              </Link>
            </div>

            {!isCaptchaConfigured && (
              <div className="rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">
                {t('auth.captchaUnavailable')}
              </div>
            )}
            {isCaptchaConfigured && (
              <div className="space-y-1">
                <HCaptcha
                  key={captchaInstanceKey}
                  sitekey={captchaSiteKey}
                  onVerify={handleCaptchaVerify}
                  onExpire={handleCaptchaExpire}
                  onError={handleCaptchaError}
                />
              </div>
            )}

            <Button
              type="submit"
              className="w-full"
              size="lg"
              isLoading={isLoading}
              disabled={!isCaptchaConfigured || !captchaToken}
            >
              {t('auth.loginButton')}
            </Button>
          </form>

          <div className="my-5 flex items-center gap-3">
            <div className="flex-1 h-px bg-zinc-800" />
            <span className="text-xs text-zinc-500">{t('auth.orContinueWith')}</span>
            <div className="flex-1 h-px bg-zinc-800" />
          </div>

          <button
            type="button"
            onClick={handleGoogleLogin}
            disabled={isLoading || isGoogleLoading}
            className="w-full flex items-center justify-center gap-3 rounded-xl border border-zinc-700 bg-zinc-800 px-4 py-2.5 text-sm font-medium text-zinc-200 transition-colors hover:border-zinc-500 hover:bg-zinc-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
              <path d="M17.64 9.205c0-.639-.057-1.252-.164-1.841H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615Z" fill="#4285F4"/>
              <path d="M9 18c2.43 0 4.467-.806 5.956-2.18l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18Z" fill="#34A853"/>
              <path d="M3.964 10.71A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.71V4.958H.957A8.996 8.996 0 0 0 0 9c0 1.452.348 2.827.957 4.042l3.007-2.332Z" fill="#FBBC05"/>
              <path d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.958L3.964 6.29C4.672 4.163 6.656 3.58 9 3.58Z" fill="#EA4335"/>
            </svg>
            {isGoogleLoading ? '…' : 'Google'}
          </button>
        </div>
      </div>
    </div>
  );
}
