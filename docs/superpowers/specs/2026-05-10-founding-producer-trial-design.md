# Founding Producer Trial System — Design Spec

**Date:** 2026-05-10  
**Status:** Approved  

---

## Contexte

Beatelion veut offrir un trial de 3 mois à tout nouvel inscrit (user ou producteur), activé manuellement par l'admin via la campagne "Founding Producers" existante. À l'expiration, l'utilisateur perd l'accès upload et sa visibilité, mais peut toujours voter aux battles. S'il souscrit via Stripe, il redevient producteur actif à part entière.

---

## Infrastructure existante réutilisée

- `user_profiles.founding_trial_start` — timestamp de début du trial
- `user_profiles.is_founding_producer` — booléen d'activation
- `user_profiles.producer_campaign_type` — référence à la campagne
- Table `producer_campaigns` avec `trial_duration` (interval, ex. `3 months`)
- Vues `get_leaderboard_producers` et `get_public_visible_producer_profiles` vérifient déjà le trial
- Dashboard admin avec activation Founding Producers — **rien à changer côté admin**

---

## Gaps à combler (4)

### Gap 1 — RLS products INSERT ne couvre pas le trial

**Problème :** La policy "Active producers can create products" exige `is_producer_active = true`. Un utilisateur en trial valide (`is_founding_producer = true`, trial non expiré) ne peut pas uploader.

**Fix :** Créer une fonction helper `private.is_in_active_trial(uid uuid)` et l'inclure dans la policy INSERT de `products` en OR avec `is_producer_active`.

```sql
CREATE OR REPLACE FUNCTION private.is_in_active_trial(uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    JOIN public.producer_campaigns pc ON pc.type = up.producer_campaign_type
    WHERE up.id = uid
      AND up.is_founding_producer = true
      AND up.founding_trial_start IS NOT NULL
      AND pc.is_active = true
      AND now() < up.founding_trial_start + pc.trial_duration
      AND COALESCE(up.is_deleted, false) = false
      AND up.deleted_at IS NULL
  );
$$;
```

La policy INSERT de `products` devient :
```
(is_producer_active = true OR private.is_in_active_trial(auth.uid()))
AND producer_id = auth.uid()
AND is_current_user_active(auth.uid())
AND ...
```

### Gap 2 — Storage policies ne couvrent pas le trial

**Problème :** Les policies INSERT sur `beats-masters`, `beats-covers`, `beats-audio` utilisent `is_active_producer(auth.uid())` qui ne vérifie que `is_producer_active = true`.

**Fix :** Mettre à jour `is_active_producer()` OU ajouter `OR private.is_in_active_trial(auth.uid())` aux 3 policies storage. Préférence : modifier `is_active_producer()` directement pour qu'elle couvre aussi le trial — un seul point de vérité.

```sql
-- Modifier is_active_producer pour inclure le trial
CREATE OR REPLACE FUNCTION public.is_active_producer(p_user uuid DEFAULT auth.uid())
RETURNS boolean ...
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = COALESCE(p_user, auth.uid())
      AND up.is_producer_active = true
  )
  OR private.is_in_active_trial(COALESCE(p_user, auth.uid()));
$$;
```

### Gap 3 — Beats restent visibles après expiration trial

**Problème :** La policy SELECT public `is_published = true` ne vérifie pas l'état du producteur. Quand le trial expire, les beats d'un producteur inactif (sans Stripe) restent visibles dans le catalogue.

**Fix :** Modifier la policy public (ou la vue `public_catalog_products`) pour exclure les beats dont le producteur a `is_producer_active = false` ET n'est plus en trial valide.

```sql
-- Condition ajoutée : le producteur doit être actif OU en trial valide
AND (
  EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = products.producer_id
      AND (up.is_producer_active = true OR private.is_in_active_trial(up.id))
  )
)
```

### Gap 4 — Pas de notification d'expiration côté frontend

**Problème :** Aucun signal n'est donné à l'utilisateur quand le trial expire ou est proche de l'expiration.

**Fix :**

1. **RPC `get_my_trial_status()`** — retourne l'état du trial pour l'utilisateur connecté :
   - `{ status: 'active', days_remaining: N }` si trial en cours
   - `{ status: 'expiring_soon', days_remaining: N }` si ≤ 7 jours
   - `{ status: 'expired' }` si expiré et pas de Stripe
   - `{ status: 'subscribed' }` si `is_producer_active = true` via Stripe
   - `{ status: 'none' }` si jamais en trial

2. **Bannière frontend** dans `ProducerDashboard.tsx` :
   - `expiring_soon` → bannière warning "Ton accès expire dans N jours — [Souscrire]"
   - `expired` → bannière bloquante "Ton trial est terminé — [Souscrire pour continuer]"

---

## Flux complet

```
Inscription (user ou producteur)
    ↓
Admin active "Founding Producer" dans le dashboard admin
(founding_trial_start = now(), is_founding_producer = true)
    ↓
J+0 à J+83 : trial actif
  ✓ Peut uploader des beats
  ✓ Profil producteur visible
  ✓ Beats visibles dans le catalogue
  ✓ Peut voter aux battles
    ↓
J+84 (J-7 avant expiration) : bannière warning dans le dashboard
  "Il te reste 7 jours — souscris pour continuer"
    ↓
J+90 : trial expiré (check dynamique, pas de cron)
  ✗ Ne peut plus uploader
  ✗ Profil masqué du catalogue producteurs
  ✗ Beats retirés du catalogue public
  ✓ Peut encore voter aux battles (utilisateur inscrit gratuit)
  → Bannière bloquante : "Souscrire pour reprendre"
    ↓
S'il souscrit via Stripe → is_producer_active = true
  → Tout revient (upload, profil, beats)
```

---

## Périmètre technique

### Migrations Supabase (4)

| # | Objet | Type |
|---|-------|------|
| 1 | `private.is_in_active_trial(uid)` | Nouvelle fonction |
| 2 | `public.is_active_producer()` | Modifier pour inclure le trial |
| 3 | Policy INSERT `products` + policy catalog SELECT | Modifier |
| 4 | `public.get_my_trial_status()` | Nouvelle RPC |

### Frontend (2 fichiers)

| Fichier | Changement |
|---------|-----------|
| `src/pages/ProducerDashboard.tsx` | Appel `get_my_trial_status()` + affichage bannière |
| `src/hooks/useTrialStatus.ts` | Hook réutilisable (nouveau fichier) |

---

## Ce qui ne change pas

- Le flow d'activation admin (Founding Producers) — déjà fonctionnel
- Le flow Stripe (souscription → `is_producer_active = true`) — inchangé
- La participation aux votes de battles — déjà accessible à tous les inscrits
- Les données en base — les beats ne sont pas supprimés, juste filtrés dynamiquement

---

## Décisions de conception

- **Expiry dynamique (pas de cron)** : l'expiration est calculée à la volée (`now() < founding_trial_start + trial_duration`). Pas de job planifié, pas de statut à maintenir. Plus simple, toujours exact.
- **`is_active_producer()` modifiée** : point de vérité unique pour "peut uploader". Les storage policies existantes bénéficient du fix automatiquement.
- **Beats non supprimés** : on filtre via les policies, pas de DELETE/UPDATE sur les produits. Si le producteur souscrit, ses beats redeviennent visibles immédiatement.
