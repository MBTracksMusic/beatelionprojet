import { useEffect, useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import {
  ArrowUpRight,
  BarChart3,
  BadgeCheck,
  Check,
  Coins,
  Flame,
  Globe2,
  Music2,
  Rocket,
  ShieldCheck,
  Sparkles,
  Target,
  Users,
  type LucideIcon,
} from 'lucide-react';
import { Button } from '../components/ui/Button';
import { Badge } from '../components/ui/Badge';
import { useAuth } from '../lib/auth/hooks';
import { supabase } from '../lib/supabase/client';
import { Card } from '../components/ui/Card';
import { Modal } from '../components/ui/Modal';
import { Input } from '../components/ui/Input';
import toast from 'react-hot-toast';
import type { Database } from '../lib/supabase/types';

type ProducerTier = 'starter' | 'pro' | 'elite';
const eliteWaitlistSource = 'elite_waitlist' as unknown as keyof Database['public']['Tables'];
const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
interface PlanItem {
  icon: LucideIcon;
  text: string;
}

const starterItems: PlanItem[] = [
  { icon: Music2, text: 'Jusqu’à 5 beats publiés' },
  { icon: Globe2, text: 'Profil public visible sur la marketplace' },
  { icon: Users, text: '1 battle communautaire par mois' },
  { icon: BarChart3, text: 'Statistiques basiques' },
  { icon: ShieldCheck, text: 'Paiements sécurisés' },
  { icon: ArrowUpRight, text: 'Passage vers PRO à tout moment' },
];

const proItems: PlanItem[] = [
  { icon: Music2, text: 'Upload illimité de beats' },
  { icon: Coins, text: 'Commission réduite à 5%' },
  { icon: Flame, text: 'Battles illimitées' },
  { icon: Rocket, text: 'Boost de visibilité sur la plateforme' },
  { icon: BadgeCheck, text: 'Badge PRO visible sur le profil' },
  { icon: BarChart3, text: 'Statistiques avancées' },
  { icon: Sparkles, text: 'Support prioritaire' },
];

interface ProfileWithTier {
  producer_tier?: ProducerTier | null;
}

const toProducerTier = (value: unknown): ProducerTier => {
  if (value === 'pro' || value === 'elite' || value === 'starter') {
    return value;
  }
  return 'starter';
};

export function PricingPage() {
  const { user, profile } = useAuth();
  const navigate = useNavigate();
  const [isPlanLoading, setIsPlanLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [plan, setPlan] = useState<{
    stripe_price_id: string;
    amount_cents: number;
    currency: string;
  } | null>(null);
  const [isEliteModalOpen, setIsEliteModalOpen] = useState(false);
  const [eliteEmail, setEliteEmail] = useState('');
  const [isEliteSubmitting, setIsEliteSubmitting] = useState(false);
  const currentTier = user
    ? toProducerTier((profile as unknown as ProfileWithTier | null)?.producer_tier)
    : null;

  useEffect(() => {
    const fetchPlan = async () => {
      setIsPlanLoading(true);
      setError(null);
      const { data, error: fetchError } = await supabase
        .from('producer_plan_config')
        .select('stripe_price_id, amount_cents, currency')
        .maybeSingle();

      if (fetchError || !data) {
        setError('Impossible de charger l’offre PRO. Réessayez plus tard.');
        setIsPlanLoading(false);
        return;
      }

      setPlan({
        stripe_price_id: data.stripe_price_id,
        amount_cents: data.amount_cents,
        currency: data.currency || 'EUR',
      });
      setIsPlanLoading(false);
    };

    void fetchPlan();
  }, []);

  const startProCheckout = async () => {
    if (!plan) return;
    if (!user) {
      navigate('/login', { state: { from: '/pricing' } });
      return;
    }
    setError(null);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      const accessToken = sessionData.session?.access_token;

      if (!accessToken) {
        throw new Error('Session expirée. Merci de vous reconnecter.');
      }

      const { data, error: fnError } = await supabase.functions.invoke('producer-checkout', {
        body: {
          price_id: plan.stripe_price_id,
          success_url: `${window.location.origin}/pricing?status=success`,
          cancel_url: `${window.location.origin}/pricing?status=cancel`,
        },
        jwt: accessToken, // force Authorization: Bearer <user token> pour la gateway
      });

      if (fnError) {
        console.error('producer-checkout error', fnError, data);
        const apiError = (data as { error?: string })?.error;
        let contextError: string | null = null;
        const context = (fnError as { context?: unknown })?.context;
        if (context instanceof Response) {
          try {
            const payload = await context.clone().json() as { error?: string; message?: string };
            contextError = payload.error || payload.message || null;
          } catch {
            try {
              const rawText = await context.clone().text();
              contextError = rawText || null;
            } catch {
              contextError = null;
            }
          }
        }
        throw new Error(
          apiError ||
          contextError ||
          `${fnError.status ?? ''} ${fnError.message || 'Checkout indisponible pour le moment.'}`.trim()
        );
      }

      const url = (data as { url?: string })?.url;
      if (url) {
        window.location.href = url;
      } else {
        throw new Error('URL de paiement manquante.');
      }
    } catch (err) {
      console.error(err);
      setError((err as Error).message);
    }
  };

  const isStarterCurrent = currentTier === 'starter';
  const isProCurrent = currentTier === 'pro';
  const isEliteCurrent = currentTier === 'elite';
  const normalizeEmail = (value: string) => value.trim().toLowerCase();

  const addToEliteWaitlist = async (rawEmail: string) => {
    const email = normalizeEmail(rawEmail);
    if (!EMAIL_REGEX.test(email)) {
      toast.error('Adresse email invalide.');
      return false;
    }

    const payload = user
      ? { email, user_id: user.id }
      : { email, user_id: null };

    const { error: insertError } = await supabase
      .from(eliteWaitlistSource)
      .insert(payload as never);

    if (insertError) {
      if ((insertError as { code?: string }).code === '23505') {
        toast.success('Vous êtes déjà inscrit. Nous vous informerons à l’ouverture ELITE.');
        return true;
      }
      console.error('elite waitlist insert error', insertError);
      toast.error('Impossible de vous inscrire pour le moment.');
      return false;
    }

    toast.success('Vous serez informé');
    return true;
  };

  const closeEliteModal = () => {
    if (isEliteSubmitting) return;
    setIsEliteModalOpen(false);
  };

  const handleEliteNotifyClick = async () => {
    if (isEliteCurrent || isEliteSubmitting) return;

    if (!user) {
      setEliteEmail('');
      setIsEliteModalOpen(true);
      return;
    }

    const accountEmail = normalizeEmail(profile?.email || user.email || '');
    if (!accountEmail) {
      toast.error('Email introuvable sur votre compte.');
      return;
    }

    setIsEliteSubmitting(true);
    try {
      await addToEliteWaitlist(accountEmail);
    } finally {
      setIsEliteSubmitting(false);
    }
  };

  const handleEliteModalSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (isEliteSubmitting) return;
    setIsEliteSubmitting(true);
    try {
      const inserted = await addToEliteWaitlist(eliteEmail);
      if (inserted) {
        setIsEliteModalOpen(false);
        setEliteEmail('');
      }
    } finally {
      setIsEliteSubmitting(false);
    }
  };

  const renderFeature = (text: string) => (
    <li className="flex items-start gap-3">
      <Check className="w-5 h-5 text-emerald-400 flex-shrink-0 mt-0.5" />
      <span className="text-zinc-300">{text}</span>
    </li>
  );

  const renderPlanItem = (item: PlanItem) => {
    const Icon = item.icon;
    return (
      <li key={item.text} className="flex items-start gap-3">
        <Icon className="w-4 h-4 text-zinc-200 flex-shrink-0 mt-1" />
        <span className="text-zinc-200/95 text-sm">{item.text}</span>
      </li>
    );
  };

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-7xl mx-auto px-4">
        <div className="text-center mb-12">
          <h1 className="text-4xl font-bold text-white mb-4">Abonnements Producteur</h1>
          <p className="text-xl text-zinc-400 max-w-2xl mx-auto">
            Choisissez la formule qui correspond à votre niveau.
          </p>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <Card className="relative h-full flex flex-col border border-emerald-700/60 bg-zinc-900 p-6">
            <div className="flex items-start justify-between gap-3 mb-6">
              <div>
                <h3 className="text-2xl font-bold text-white mb-1">Producteur STARTER</h3>
                <p className="text-zinc-200 font-semibold">Lance-toi. Teste. Commence à vendre.</p>
                <p className="text-zinc-400 text-sm mt-1 flex items-start gap-2">
                  <Target className="w-4 h-4 mt-0.5 text-zinc-300" />
                  Idéal pour découvrir la plateforme et faire tes premières ventes.
                </p>
              </div>
              {isStarterCurrent && <Badge variant="success">Plan actuel</Badge>}
            </div>

            <div className="mb-5">
              <span className="text-4xl font-bold text-white">Gratuit</span>
            </div>

            <div className="mb-3 flex items-center gap-2">
              <Check className="w-5 h-5 text-emerald-400" />
              <p className="text-xl font-bold text-white">Ce qui est inclus</p>
            </div>
            <ul className="space-y-2 mb-6">
              {starterItems.map(renderPlanItem)}
            </ul>

            <div className="mb-6 p-3 rounded-lg border border-zinc-800 bg-zinc-950/60">
              <p className="text-white font-semibold flex items-center gap-2">
                <Coins className="w-4 h-4 text-amber-300" />
                Commission
              </p>
              <p className="text-zinc-200 text-sm mt-1">12% sur chaque vente</p>
              <p className="text-zinc-400 text-xs mt-1">Tu ne paies que si tu vends.</p>
            </div>

            <div className="mt-auto pt-6">
              {user ? (
                <Button
                  className="w-full"
                  variant="secondary"
                  size="lg"
                  disabled={isStarterCurrent}
                  onClick={() => navigate('/dashboard')}
                >
                  {isStarterCurrent ? 'Plan actuel' : 'Commencer'}
                </Button>
              ) : (
                <Link to="/register">
                  <Button
                    className="w-full"
                    variant="secondary"
                    size="lg"
                  >
                    Commencer
                  </Button>
                </Link>
              )}
            </div>
          </Card>

          <Card className="relative h-full flex flex-col border border-rose-500 bg-zinc-900 p-6">
            <div className="flex items-start justify-between gap-3 mb-6">
              <div>
                <h3 className="text-2xl font-bold text-white mb-1">Producteur PRO</h3>
                <p className="text-zinc-200 font-semibold">Accélère ta croissance. Gagne en visibilité.</p>
                <p className="text-zinc-400 text-sm mt-1 flex items-start gap-2">
                  <Target className="w-4 h-4 mt-0.5 text-zinc-300" />
                  Idéal pour les producteurs qui veulent scaler.
                </p>
              </div>
              {isProCurrent && <Badge variant="premium">Plan actuel</Badge>}
            </div>

            <div className="mb-6">
              <span className="text-4xl font-bold text-white">19,99€</span>
              <span className="text-zinc-400"> / mois</span>
            </div>

            <div className="mb-3 flex items-center gap-2">
              <Check className="w-5 h-5 text-emerald-400" />
              <p className="text-xl font-bold text-white">Inclus</p>
            </div>
            <ul className="space-y-2 mb-8">
              {proItems.map(renderPlanItem)}
            </ul>

            <div className="mt-auto pt-6">
              {error && (
                <div className="mb-4 text-sm text-red-400 bg-red-900/20 border border-red-800 rounded-lg px-3 py-2">
                  {error}
                </div>
              )}

              <Button
                className="w-full"
                variant="primary"
                size="lg"
                disabled={isProCurrent || isPlanLoading || !plan}
                onClick={startProCheckout}
              >
                {isProCurrent ? 'Plan actuel' : 'Choisir PRO'}
              </Button>
            </div>
          </Card>

          <Card className="relative h-full flex flex-col border border-red-700/60 bg-zinc-900 p-6">
            <div className="flex items-start justify-between gap-3 mb-6">
              <div>
                <h3 className="text-2xl font-bold text-white mb-1">Producteur ELITE</h3>
                <p className="text-zinc-200 font-semibold">Le niveau supérieur.</p>
                <p className="text-zinc-100 text-4xl leading-none mt-2">Bientôt disponible.</p>
                <p className="text-zinc-400 text-sm mt-2 flex items-start gap-2">
                  <Target className="w-4 h-4 mt-0.5 text-zinc-300" />
                  Conçu pour les producteurs les plus ambitieux.
                </p>
              </div>
              {isEliteCurrent && <Badge variant="danger">Plan actuel</Badge>}
            </div>

            <div className="mt-auto pt-6">
              <Button
                className="w-full"
                variant="outline"
                size="lg"
                disabled={isEliteCurrent || isEliteSubmitting}
                onClick={handleEliteNotifyClick}
              >
                {isEliteCurrent ? 'Plan actuel' : 'M’informer quand disponible'}
              </Button>
            </div>
          </Card>
        </div>

        <div className="mt-16 text-center">
          <p className="text-zinc-400 mb-4">Des questions sur nos offres ?</p>
          <Link to="/contact">
            <Button variant="ghost">Contactez-nous</Button>
          </Link>
        </div>
      </div>

      <Modal
        isOpen={isEliteModalOpen}
        onClose={closeEliteModal}
        title="Liste d’attente ELITE"
        description="Entrez votre email pour être informé dès l’ouverture."
        size="sm"
      >
        <form onSubmit={handleEliteModalSubmit} className="space-y-4">
          <Input
            type="email"
            label="Email"
            value={eliteEmail}
            onChange={(event) => setEliteEmail(event.target.value)}
            placeholder="email@exemple.com"
            autoComplete="email"
            required
          />
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              onClick={closeEliteModal}
              disabled={isEliteSubmitting}
            >
              Annuler
            </Button>
            <Button type="submit" isLoading={isEliteSubmitting}>
              Me prévenir
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
