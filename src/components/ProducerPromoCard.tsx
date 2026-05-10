import { useRef, useState } from 'react';
import type { FormEvent } from 'react';
import HCaptcha from '@hcaptcha/react-hcaptcha';
import { Check, Crown, Sparkles } from 'lucide-react';
import { supabase } from '../lib/supabase/client';
import { Button } from './ui/Button';
import { Card } from './ui/Card';
import { Input } from './ui/Input';
import { Modal } from './ui/Modal';
import toast from 'react-hot-toast';
import type { PricingProducerPromo } from '../lib/supabase/useMaintenanceMode';

const CAPTCHA_SITE_KEY =
  (import.meta.env.VITE_HCAPTCHA_SITE_KEY as string | undefined)?.trim() ?? '';

const PROMO_FEATURES = [
  "Test de l'espace producteur",
  'Participation au lancement',
  'Validation prioritaire',
  'Accès par sélection',
];

interface ProducerPromoCardProps {
  promo: PricingProducerPromo;
  isActiveProducer: boolean;
  userEmail?: string;
}

type SubmitState = 'idle' | 'loading' | 'done';

export function ProducerPromoCard({ promo, isActiveProducer, userEmail = '' }: ProducerPromoCardProps) {
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [email, setEmail] = useState(userEmail);
  const [submitState, setSubmitState] = useState<SubmitState>('idle');
  const [captchaKey, setCaptchaKey] = useState(0);
  const captchaTokenRef = useRef<string | null>(null);

  if (isActiveProducer) return null;

  const isCaptchaConfigured = CAPTCHA_SITE_KEY.length > 0;

  const handleOpen = () => {
    setEmail(userEmail);
    setSubmitState('idle');
    setCaptchaKey((k) => k + 1);
    captchaTokenRef.current = null;
    setIsModalOpen(true);
  };

  const handleClose = () => {
    if (submitState === 'loading') return;
    setIsModalOpen(false);
  };

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (submitState !== 'idle') return;

    if (isCaptchaConfigured && !captchaTokenRef.current) {
      toast.error('Validez le captcha avant de continuer');
      return;
    }

    setSubmitState('loading');
    try {
      const { data, error } = await supabase.functions.invoke<{ message?: string; error?: string }>('join-waitlist', {
        body: {
          email: email.trim().toLowerCase(),
          captchaToken: captchaTokenRef.current,
          source: 'pricing_producer_promo',
          campaign_type: promo.campaign_type || null,
        },
      });

      if (error) throw error;

      const msg = (data as { message?: string; error?: string } | null);

      if (msg?.error === 'invalid_email') {
        toast.error('Adresse email invalide.');
        setSubmitState('idle');
        return;
      }
      if (msg?.error === 'captcha_failed') {
        toast.error('Captcha invalide, réessayez.');
        setCaptchaKey((k) => k + 1);
        captchaTokenRef.current = null;
        setSubmitState('idle');
        return;
      }
      if (msg?.error === 'rate_limit_exceeded') {
        toast.error('Trop de tentatives, réessayez plus tard.');
        setSubmitState('idle');
        return;
      }

      setSubmitState('done');
    } catch (err) {
      console.error('[ProducerPromoCard] join-waitlist error', err);
      toast.error('Une erreur est survenue, réessayez.');
      setSubmitState('idle');
    }
  };

  return (
    <>
      <Card className="flex h-full flex-col justify-between border border-amber-500/70 bg-zinc-900 p-6 shadow-[0_0_30px_rgba(245,158,11,0.10)] transition-all duration-300 hover:-translate-y-2 hover:shadow-[0_0_40px_rgba(245,158,11,0.18)]">
        <div>
          <div className="mb-4 flex justify-center">
            <span className="rounded-full bg-gradient-to-r from-amber-500 to-orange-500 px-3 py-1 text-xs font-semibold text-white shadow-md">
              Phase privée · Sélection
            </span>
          </div>

          <div className="mb-6">
            <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-xl border border-amber-500/30 bg-amber-500/10">
              <Crown className="h-6 w-6 text-amber-400" />
            </div>
            <h3 className="mb-1 text-2xl font-bold text-white">{promo.title}</h3>
            <p className="font-semibold text-zinc-200">Accès privé · Sélection manuelle</p>
            <p className="mt-1 flex items-center gap-2 text-sm text-zinc-400">
              <Sparkles className="h-4 w-4 flex-shrink-0 text-amber-400" />
              20 places disponibles
            </p>
          </div>

          <div className="mb-6">
            <span className="text-4xl font-bold text-white">Gratuit</span>
            <span className="text-zinc-400"> · Candidature</span>
          </div>

          <div className="mb-6 rounded-xl border border-amber-400/20 bg-amber-500/10 p-4">
            <p className="text-sm leading-relaxed text-amber-100/90">{promo.message}</p>
          </div>

          <div className="mb-3 flex items-center gap-2">
            <Check className="h-5 w-5 text-amber-400" />
            <p className="text-xl font-bold text-white">Inclus</p>
          </div>
          <ul className="mb-6 space-y-2">
            {PROMO_FEATURES.map((feature) => (
              <li key={feature} className="flex items-start gap-3">
                <Check className="mt-1 h-4 w-4 flex-shrink-0 text-amber-400" />
                <span className="text-sm text-zinc-200/95">{feature}</span>
              </li>
            ))}
          </ul>

          <p className="mb-2 text-center text-xs text-zinc-500">
            Demande gratuite · Validation manuelle
          </p>
        </div>

        <div className="pt-6">
          <Button
            className="mt-auto w-full"
            variant="primary"
            size="lg"
            onClick={handleOpen}
          >
            {promo.button_label}
          </Button>
        </div>
      </Card>

      <Modal
        isOpen={isModalOpen}
        onClose={handleClose}
        title={promo.title}
        description={promo.message}
        size="sm"
      >
        {submitState === 'done' ? (
          <div className="py-4 text-center">
            <p className="font-semibold text-emerald-400">Demande envoyée !</p>
            <p className="mt-2 text-sm text-zinc-400">On te recontacte dès que possible.</p>
            <Button className="mt-6 w-full" variant="secondary" onClick={handleClose}>
              Fermer
            </Button>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4">
            <Input
              type="email"
              label="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="ton@email.com"
              autoComplete="email"
              required
              disabled={submitState === 'loading'}
            />
            {isCaptchaConfigured && (
              <div className="flex justify-center">
                <HCaptcha
                  key={captchaKey}
                  sitekey={CAPTCHA_SITE_KEY}
                  onVerify={(token) => { captchaTokenRef.current = token; }}
                  onExpire={() => { captchaTokenRef.current = null; }}
                  onError={() => { captchaTokenRef.current = null; }}
                />
              </div>
            )}
            <div className="flex justify-end gap-2 pt-2">
              <Button
                type="button"
                variant="ghost"
                onClick={handleClose}
                disabled={submitState === 'loading'}
              >
                Annuler
              </Button>
              <Button type="submit" isLoading={submitState === 'loading'}>
                {promo.button_label}
              </Button>
            </div>
          </form>
        )}
      </Modal>
    </>
  );
}
