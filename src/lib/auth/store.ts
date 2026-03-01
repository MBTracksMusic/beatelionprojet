import { create } from 'zustand';
import type { User, Session } from '@supabase/supabase-js';
import type { UserProfile } from '../supabase/types';
import { supabase } from '../supabase/client';

interface AuthState {
  user: User | null;
  session: Session | null;
  profile: UserProfile | null;
  isLoading: boolean;
  isInitialized: boolean;
  setUser: (user: User | null) => void;
  setSession: (session: Session | null) => void;
  setProfile: (profile: UserProfile | null) => void;
  setLoading: (loading: boolean) => void;
  setInitialized: (initialized: boolean) => void;
  fetchProfile: () => Promise<void>;
  signOut: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set, get) => ({
  user: null,
  session: null,
  profile: null,
  isLoading: true,
  isInitialized: false,

  setUser: (user) => set({ user }),
  setSession: (session) => set({ session }),
  setProfile: (profile) => set({ profile }),
  setLoading: (isLoading) => set({ isLoading }),
  setInitialized: (isInitialized) => set({ isInitialized }),

  fetchProfile: async () => {
    const { user } = get();
    if (!user) {
      set({ profile: null });
      return;
    }

    const { data, error } = await supabase
      .from('my_user_profile')
      .select('id, user_id, username, full_name, avatar_url, role, producer_tier, is_producer_active, total_purchases, confirmed_at, producer_verified_at, battle_refusal_count, battles_participated, battles_completed, engagement_score, language, bio, website_url, social_links, created_at, updated_at')
      .maybeSingle();

    if (error) {
      console.error('Error fetching profile:', error);
      return;
    }

    if (!data) {
      set({ profile: null });
      return;
    }

    const row = data as Record<string, unknown>;

    set({
      profile: {
        id: typeof row.id === 'string' && row.id.length > 0 ? row.id : user.id,
        email: user.email ?? '',
        username: typeof row.username === 'string' ? row.username : null,
        full_name: typeof row.full_name === 'string' ? row.full_name : null,
        avatar_url: typeof row.avatar_url === 'string' ? row.avatar_url : null,
        role:
          row.role === 'visitor' ||
          row.role === 'user' ||
          row.role === 'confirmed_user' ||
          row.role === 'producer' ||
          row.role === 'admin'
            ? row.role
            : 'user',
        is_confirmed: row.confirmed_at != null,
        is_producer_active: row.is_producer_active === true,
        producer_tier:
          row.producer_tier === 'starter' || row.producer_tier === 'pro' || row.producer_tier === 'elite'
            ? row.producer_tier
            : null,
        stripe_customer_id: null,
        stripe_subscription_id: null,
        subscription_status: null,
        total_purchases: typeof row.total_purchases === 'number' ? row.total_purchases : 0,
        confirmed_at: typeof row.confirmed_at === 'string' ? row.confirmed_at : null,
        producer_verified_at: typeof row.producer_verified_at === 'string' ? row.producer_verified_at : null,
        battle_refusal_count: typeof row.battle_refusal_count === 'number' ? row.battle_refusal_count : 0,
        battles_participated: typeof row.battles_participated === 'number' ? row.battles_participated : 0,
        battles_completed: typeof row.battles_completed === 'number' ? row.battles_completed : 0,
        engagement_score: typeof row.engagement_score === 'number' ? row.engagement_score : 0,
        language: row.language === 'en' || row.language === 'de' ? row.language : 'fr',
        bio: typeof row.bio === 'string' ? row.bio : null,
        website_url: typeof row.website_url === 'string' ? row.website_url : null,
        social_links:
          row.social_links && typeof row.social_links === 'object' && !Array.isArray(row.social_links)
            ? (row.social_links as Record<string, string>)
            : {},
        created_at: typeof row.created_at === 'string' ? row.created_at : new Date().toISOString(),
        updated_at: typeof row.updated_at === 'string' ? row.updated_at : new Date().toISOString(),
      } satisfies UserProfile,
    });
  },

  signOut: async () => {
    await supabase.auth.signOut();
    set({ user: null, session: null, profile: null });
  },
}));

export function initializeAuth() {
  const { setUser, setSession, setLoading, setInitialized, fetchProfile } = useAuthStore.getState();

  supabase.auth.getSession().then(({ data: { session } }) => {
    setSession(session);
    setUser(session?.user ?? null);
    if (session?.user) {
      fetchProfile();
    }
    setLoading(false);
    setInitialized(true);
  });

  const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
    (async () => {
      setSession(session);
      setUser(session?.user ?? null);
      if (session?.user) {
        await fetchProfile();
      } else {
        useAuthStore.setState({ profile: null });
      }
      setLoading(false);
    })();
  });

  return () => {
    subscription.unsubscribe();
  };
}
