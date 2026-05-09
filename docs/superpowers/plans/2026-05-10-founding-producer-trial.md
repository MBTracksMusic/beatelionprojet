# Founding Producer Trial System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permettre aux producteurs en trial Founding Producer d'uploader, puis masquer leur profil et leurs beats à l'expiration du trial (3 mois), avec une bannière d'alerte dans le dashboard.

**Architecture:** Une migration Supabase unique ajoute la fonction helper `private.is_in_active_trial()`, met à jour `is_active_producer()` pour couvrir le trial, corrige les policies RLS de `products`, et expose la RPC `get_my_trial_status()`. Le frontend lit cette RPC via un hook `useTrialStatus` et affiche une bannière dans `ProducerDashboard`.

**Tech Stack:** PostgreSQL/Supabase RLS, TypeScript, React, Supabase JS client v2, Lucide React

---

## Fichiers touchés

| Fichier | Action |
|---------|--------|
| `supabase/migrations/20260510000000_founding_producer_trial_system.sql` | Créer |
| `src/hooks/useTrialStatus.ts` | Créer |
| `src/pages/ProducerDashboard.tsx` | Modifier (import + bannière) |

---

## Task 1 — Migration DB : fonctions + policies

**Files:**
- Create: `supabase/migrations/20260510000000_founding_producer_trial_system.sql`

- [ ] **Étape 1 : Créer le fichier de migration**

```sql
-- supabase/migrations/20260510000000_founding_producer_trial_system.sql

-- ─── 1. Fonction helper : détecte un trial Founding Producer actif ──────────
-- Utilisée par is_active_producer() et les policies SELECT du catalogue.
-- Fallback : interval '3 months' si aucune campagne liée (producer_campaign_type IS NULL).
CREATE OR REPLACE FUNCTION private.is_in_active_trial(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
    WHERE up.id = uid
      AND up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND now() < up.founding_trial_start + COALESCE(pc.trial_duration, interval '3 months')
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  );
$$;

-- ─── 2. Mettre à jour is_active_producer() pour inclure le trial ─────────────
-- Toutes les storage policies (beats-masters, beats-covers, beats-audio) appellent
-- is_active_producer() — elles bénéficient automatiquement de ce changement.
CREATE OR REPLACE FUNCTION public.is_active_producer(p_user uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  uid uuid := COALESCE(p_user, auth.uid());
BEGIN
  IF uid IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = uid AND up.is_producer_active = true
  )
  OR private.is_in_active_trial(uid);
END;
$$;

-- ─── 3. Policy INSERT products : autoriser les producteurs en trial ───────────
-- Remplace le check explicite is_producer_active=true par is_active_producer()
-- qui couvre désormais le trial. La garde Elite reste inchangée.
DROP POLICY IF EXISTS "Active producers can create products" ON public.products;
CREATE POLICY "Active producers can create products"
ON public.products
FOR INSERT
TO authenticated
WITH CHECK (
  producer_id = auth.uid()
  AND is_current_user_active(auth.uid())
  AND is_active_producer(auth.uid())
  AND (
    COALESCE(is_elite, false) = false
    OR EXISTS (
      SELECT 1 FROM public.user_profiles up
      WHERE up.id = auth.uid()
        AND up.account_type = 'elite_producer'
        AND is_active_producer(up.id)
        AND COALESCE(up.is_deleted, false) = false
        AND up.deleted_at IS NULL
    )
  )
  AND (
    NOT (product_type = 'beat' AND is_published = true AND deleted_at IS NULL)
    OR private.can_publish_beat(auth.uid(), NULL::uuid)
  )
);

-- ─── 4. Policy SELECT catalogue public : masquer les beats des trials expirés ─
-- "Public read products simple" (qual=true pour anon) est trop permissive :
-- elle expose les produits non publiés. On la supprime — "Public can view published
-- products" (roles PUBLIC) couvre déjà anon et authenticated.
DROP POLICY IF EXISTS "Public read products simple" ON public.products;

-- Mettre à jour la policy publique pour filtrer les producteurs inactifs
DROP POLICY IF EXISTS "Public can view published products" ON public.products;
CREATE POLICY "Public can view published products"
ON public.products
FOR SELECT
TO PUBLIC
USING (
  is_published = true
  AND is_active_producer(producer_id)
);

-- ─── 5. RPC get_my_trial_status() ─────────────────────────────────────────────
-- Retourne le statut du trial pour l'utilisateur connecté.
-- Statuts possibles : 'subscribed' | 'active' | 'expiring_soon' | 'expired' | 'none'
-- 'expiring_soon' = trial valide mais ≤ 7 jours restants
CREATE OR REPLACE FUNCTION public.get_my_trial_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH trial_info AS (
    SELECT
      up.is_producer_active,
      up.is_founding_producer,
      up.founding_trial_start,
      COALESCE(pc.trial_duration, interval '3 months') AS trial_duration
    FROM public.user_profiles up
    LEFT JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
    WHERE up.id = auth.uid()
  )
  SELECT CASE
    WHEN ti.is_producer_active = true
      THEN jsonb_build_object('status', 'subscribed')
    WHEN ti.is_founding_producer = true AND ti.founding_trial_start IS NOT NULL THEN
      CASE
        WHEN now() >= ti.founding_trial_start + ti.trial_duration
          THEN jsonb_build_object('status', 'expired')
        WHEN now() >= ti.founding_trial_start + ti.trial_duration - interval '7 days'
          THEN jsonb_build_object(
            'status', 'expiring_soon',
            'days_remaining', GREATEST(1, EXTRACT(DAY FROM (ti.founding_trial_start + ti.trial_duration - now()))::int)
          )
        ELSE jsonb_build_object(
          'status', 'active',
          'days_remaining', EXTRACT(DAY FROM (ti.founding_trial_start + ti.trial_duration - now()))::int
        )
      END
    ELSE jsonb_build_object('status', 'none')
  END
  FROM trial_info ti;
$$;

-- Accès RPC : utilisateur authentifié uniquement
REVOKE ALL ON FUNCTION public.get_my_trial_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_trial_status() TO authenticated;
```

- [ ] **Étape 2 : Appliquer la migration en production**

```bash
npx supabase db push
```

Résultat attendu : `Applying migration 20260510000000_founding_producer_trial_system.sql... done`

- [ ] **Étape 3 : Vérifier is_in_active_trial() avec uweboomin (producteur actif — doit retourner false car pas en trial)**

Via Supabase MCP ou SQL editor :
```sql
SELECT private.is_in_active_trial('70e2ffd7-2666-430c-86dd-0c58c607cd1f');
-- Attendu : false (is_producer_active=true via Stripe, pas via trial)
```

- [ ] **Étape 4 : Vérifier is_active_producer() avec uweboomin (doit retourner true via is_producer_active)**

```sql
SELECT is_active_producer('70e2ffd7-2666-430c-86dd-0c58c607cd1f');
-- Attendu : true
```

- [ ] **Étape 5 : Simuler un producteur en trial — créer un test temporaire**

```sql
-- Simuler un user en trial actif
WITH fake_trial AS (
  UPDATE public.user_profiles
  SET is_founding_producer = true,
      founding_trial_start = now() - interval '1 month'
  WHERE id = '70e2ffd7-2666-430c-86dd-0c58c607cd1f'
  RETURNING id
)
SELECT private.is_in_active_trial('70e2ffd7-2666-430c-86dd-0c58c607cd1f');
-- Attendu : true (trial a commencé il y a 1 mois, expire dans 2 mois)
```

```sql
-- Simuler un trial expiré
UPDATE public.user_profiles
SET founding_trial_start = now() - interval '4 months'
WHERE id = '70e2ffd7-2666-430c-86dd-0c58c607cd1f';

SELECT private.is_in_active_trial('70e2ffd7-2666-430c-86dd-0c58c607cd1f');
-- Attendu : false (trial expiré)
```

- [ ] **Étape 6 : Remettre uweboomin à son état normal**

```sql
UPDATE public.user_profiles
SET is_founding_producer = false,
    founding_trial_start = NULL
WHERE id = '70e2ffd7-2666-430c-86dd-0c58c607cd1f';
```

- [ ] **Étape 7 : Vérifier get_my_trial_status() retourne 'subscribed' pour uweboomin**

```sql
SET LOCAL role = authenticated;
SET LOCAL request.jwt.claims = '{"sub": "70e2ffd7-2666-430c-86dd-0c58c607cd1f", "role": "authenticated"}';
SELECT get_my_trial_status();
-- Attendu : {"status": "subscribed"}
```

- [ ] **Étape 8 : Commit**

```bash
git add supabase/migrations/20260510000000_founding_producer_trial_system.sql
git commit -m "feat(db): founding producer trial — is_in_active_trial, is_active_producer update, product policies, get_my_trial_status RPC"
```

---

## Task 2 — Hook `useTrialStatus`

**Files:**
- Create: `src/hooks/useTrialStatus.ts`

- [ ] **Étape 1 : Créer le hook**

```typescript
// src/hooks/useTrialStatus.ts
import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';

export type TrialStatus =
  | { status: 'loading' }
  | { status: 'subscribed' }
  | { status: 'active'; days_remaining: number }
  | { status: 'expiring_soon'; days_remaining: number }
  | { status: 'expired' }
  | { status: 'none' };

export function useTrialStatus(): TrialStatus {
  const [trialStatus, setTrialStatus] = useState<TrialStatus>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function fetchStatus() {
      const { data, error } = await supabase.rpc('get_my_trial_status');
      if (cancelled) return;
      if (error || !data) {
        setTrialStatus({ status: 'none' });
        return;
      }
      setTrialStatus(data as TrialStatus);
    }

    fetchStatus();
    return () => { cancelled = true; };
  }, []);

  return trialStatus;
}
```

- [ ] **Étape 2 : Vérifier que TypeScript compile sans erreur**

```bash
npx tsc --noEmit 2>&1 | grep useTrialStatus
# Attendu : aucune sortie (pas d'erreur sur ce fichier)
```

- [ ] **Étape 3 : Commit**

```bash
git add src/hooks/useTrialStatus.ts
git commit -m "feat(hooks): useTrialStatus — poll get_my_trial_status RPC"
```

---

## Task 3 — Bannière trial dans `ProducerDashboard`

**Files:**
- Modify: `src/pages/ProducerDashboard.tsx`

- [ ] **Étape 1 : Ajouter l'import AlertTriangle et useTrialStatus**

Ligne 3 (bloc import lucide-react existant), ajouter `AlertTriangle` :
```typescript
import { Music, BarChart3, ShoppingBag, UploadCloud, Trash2, AlertTriangle } from 'lucide-react';
```

Après les imports existants (après la ligne `import { PrivateAccessCard }...`), ajouter :
```typescript
import { useTrialStatus } from '@/hooks/useTrialStatus';
```

- [ ] **Étape 2 : Appeler le hook dans le composant**

Dans `ProducerDashboardPage()`, après la ligne `const [nudgeDismissed, setNudgeDismissed] = useState(false);` (ligne ~184), ajouter :
```typescript
  const trialStatus = useTrialStatus();
```

- [ ] **Étape 3 : Insérer la bannière après `<PrivateAccessCard />`**

Ligne 765 dans le JSX, après `<PrivateAccessCard profile={profile} />`, ajouter :
```tsx
        {(trialStatus.status === 'expiring_soon' || trialStatus.status === 'expired') && (
          <div className={`rounded-xl border p-4 flex items-start gap-3 ${
            trialStatus.status === 'expired'
              ? 'border-red-800 bg-red-950/40'
              : 'border-yellow-700 bg-yellow-950/40'
          }`}>
            <AlertTriangle className={`mt-0.5 h-5 w-5 shrink-0 ${
              trialStatus.status === 'expired' ? 'text-red-400' : 'text-yellow-400'
            }`} />
            <div className="flex-1">
              <p className={`font-semibold text-sm ${
                trialStatus.status === 'expired' ? 'text-red-300' : 'text-yellow-300'
              }`}>
                {trialStatus.status === 'expired'
                  ? 'Ton accès Founding Producer est terminé'
                  : `Ton accès expire dans ${trialStatus.days_remaining} jour${trialStatus.days_remaining > 1 ? 's' : ''}`}
              </p>
              <p className="text-xs text-zinc-400 mt-1">
                {trialStatus.status === 'expired'
                  ? 'Tu ne peux plus uploader de nouveaux beats ni apparaître dans le catalogue. Souscris pour reprendre.'
                  : 'Souscris maintenant pour maintenir ton accès producteur.'}
              </p>
            </div>
            <Link
              to="/tarifs"
              className="shrink-0 rounded-lg bg-white px-3 py-1.5 text-xs font-semibold text-black hover:bg-zinc-100 transition"
            >
              Souscrire →
            </Link>
          </div>
        )}
```

- [ ] **Étape 4 : Vérifier TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep -E "ProducerDashboard|useTrialStatus"
# Attendu : aucune sortie
```

- [ ] **Étape 5 : Vérifier visuellement en dev**

```bash
npm run dev
```

Se connecter en tant qu'un producteur avec trial actif (ou simuler en mettant temporairement `founding_trial_start = now() - interval '83 days'` en DB). Vérifier que la bannière jaune apparaît. Mettre `now() - interval '91 days'` et vérifier la bannière rouge.

- [ ] **Étape 6 : Commit**

```bash
git add src/pages/ProducerDashboard.tsx
git commit -m "feat(ui): trial expiry banner in ProducerDashboard"
```

---

## Vérification finale

Après les 3 tasks, tester le flux complet :

1. **Trial actif (< 83 jours écoulés)** → pas de bannière, upload autorisé ✓
2. **Trial expiring soon (83-90 jours)** → bannière jaune + lien /tarifs ✓
3. **Trial expiré (> 90 jours)** → bannière rouge, beats retirés du catalogue public ✓
4. **Producteur Stripe actif** → aucune bannière, accès complet ✓
5. **User sans trial** → aucune bannière ✓
