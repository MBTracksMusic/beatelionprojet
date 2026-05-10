import { useRef, useState } from 'react';
import type { FormEvent } from 'react';
import HCaptcha from '@hcaptcha/react-hcaptcha';
import { Sparkles } from 'lucide-react';
import { supabase } from '../lib/supabase/client';
import { Button } from './ui/Button';
import { Card } from './ui/Card';
import { Input } from './ui/Input';
import { Modal } from './ui/Modal';
import toast from 'react-hot-toast';
import type { PricingProducerPromo } from '../lib/supabase/useMaintenanceMode';

const CAPTCHA_SITE_KEY =
  (import.meta.env.VITE_HCAPTCHA_SITE_KEY as string | undefined)?.trim() ?? '';

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
      <Card className="border border-amber-500/40 bg-gradient-to-br from-amber-950/20 to-zinc-900 p-8">
        <div className="flex flex-col items-center gap-4 text-center sm:flex-row sm:gap-8 sm:text-left">
          <div className="flex h-14 w-14 flex-shrink-0 items-center justify-center rounded-2xl border border-amber-500/30 bg-amber-500/15">
            <Sparkles className="h-7 w-7 text-amber-400" />
          </div>
          <div className="min-w-0 flex-1">
            <h3 className="mb-2 text-xl font-bold text-white">{promo.title}</h3>
            <p className="text-sm leading-relaxed text-zinc-400">{promo.message}</p>
          </div>
          <div className="flex-shrink-0">
            <Button variant="primary" size="lg" onClick={handleOpen}>
              {promo.button_label}
            </Button>
          </div>
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
