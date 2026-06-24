# Battle « Accepter avec son beat » — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permettre de défier un producteur sans beat ; au moment d'accepter, le producteur 2 choisit un de ses beats (même genre que la battle) pour valider, sinon il refuse.

**Architecture:** Côté DB, `respond_to_battle` reçoit un nouveau paramètre `p_product2_id` (validé + attaché atomiquement, en rejouant la validation admin) et `private.rpc_create_battle` rend product1 obligatoire ; un helper `is_battle_product_genre_match` garantit la cohérence de genre des deux côtés. Côté front, le formulaire de création exige product1, et chaque carte d'invitation reçue affiche le genre demandé + un sélecteur de beat filtré par ce genre (beats occupés grisés, lien upload si aucun beat éligible).

**Tech Stack:** PostgreSQL (Supabase migrations, plpgsql, SECURITY DEFINER), React + TypeScript (Vite), supabase-js RPC, i18n maison (`src/lib/i18n/translations/*.ts`).

## Global Constraints

- Nouvelle migration nommée `supabase/migrations/20260624120000_battle_accept_with_beat.sql` — timestamp **postérieur** à `20260624073000` (dont elle dépend pour la version canonique de `assert_battle_create_validations`). Vérifier avant de créer qu'aucune migration `2026062412*` plus récente n'existe ; sinon incrémenter.
- Déploiement **file-based** via `supabase db push`. Si MCP `apply_migration` est utilisé, **réaligner `schema_migrations.version`** après (contrainte connue : `apply_migration` génère sa propre version distante et casse les `db push` suivants).
- La logique de création vit dans **`private.rpc_create_battle`** (déplacée par `20260603123000`), avec un wrapper `public.rpc_create_battle` SECURITY INVOKER inchangé. Ne PAS recréer le wrapper public (signature inchangée).
- `respond_to_battle` est en **`public`**, SECURITY DEFINER, **non wrappé**. Ajouter un 4ᵉ paramètre = changement de signature → `DROP FUNCTION public.respond_to_battle(uuid, boolean, text)` PUIS `CREATE` la version 4-args (sinon l'ancienne signature subsiste et permet encore d'accepter sans beat).
- Éligibilité d'un beat de battle (règle existante, à respecter côté front comme côté serveur) : `product_type='beat'`, `status='active'`, `is_published=true`, `deleted_at IS NULL`, appartenant au producteur.
- i18n : toute nouvelle clé doit être ajoutée dans les **4** fichiers `fr.ts`, `en.ts`, `es.ts`, `de.ts` sous le bloc `producerBattles:`. Style des valeurs existantes : sans accents techniques particuliers, phrases courtes (voir clés voisines).
- Le worker audio Render pointe sur la **prod** ; toute migration appliquée touche la prod.
- Commandes de vérification du repo : `npm run typecheck` · `npm run lint` · `npm run test:unit` · `npm run supabase:types`.

---

### Task 1: Migration SQL — helper genre + product1 obligatoire à la création + `respond_to_battle` avec beat

**Files:**
- Create: `supabase/migrations/20260624120000_battle_accept_with_beat.sql`

**Interfaces:**
- Consumes (fonctions existantes inchangées) : `public.is_battle_product_eligible(uuid,uuid)`, `public.assert_battle_create_validations(uuid,uuid,uuid,uuid,boolean,integer)`, `public.assert_battle_product_monthly_caps(uuid,uuid,uuid)`, `public.is_battle_genre_eligible(uuid)`, trigger `trg_sync_battle_product_locks_write` sur `public.battles`.
- Produces :
  - `public.is_battle_product_genre_match(p_product_id uuid, p_genre_id uuid) RETURNS boolean`
  - `private.rpc_create_battle(...)` (même signature, product1 désormais requis)
  - `public.respond_to_battle(p_battle_id uuid, p_accept boolean, p_reason text DEFAULT NULL, p_product2_id uuid DEFAULT NULL) RETURNS boolean`
  - Nouveaux codes d'erreur (texte du `RAISE`) : `BATTLE_PRODUCT1_REQUIRED`, `BATTLE_PRODUCT1_GENRE_MISMATCH`, `BATTLE_PRODUCT2_REQUIRED`, `BATTLE_PRODUCT2_GENRE_MISMATCH`.

- [ ] **Step 1: Créer le fichier de migration avec le contenu complet ci-dessous**

```sql
/*
  # Battle: accepter avec son beat (producteur 2)

  - Helper is_battle_product_genre_match : cohérence de genre d'un beat vs la battle.
  - private.rpc_create_battle : product1 (beat du créateur) devient obligatoire ;
    product1 (et product2 s'il est fourni) doivent être du genre de la battle.
  - public.respond_to_battle : nouveau paramètre p_product2_id. Sur accept, le beat
    est obligatoire, validé (éligibilité, genre, validation admin complète, cap mensuel)
    puis attaché ; le trigger de lock garantit l'anti-occupation. Refus inchangé.

  Dépend de 20260624073000 (version canonique de assert_battle_create_validations).
*/

BEGIN;

-- 1) Helper de cohérence de genre -------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_battle_product_genre_match(
  p_product_id uuid,
  p_genre_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_genre_id IS NULL
    OR EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.id = p_product_id
        AND p.genre_id = p_genre_id
    );
$$;

REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_battle_product_genre_match(uuid, uuid) TO service_role;

-- 2) Création : product1 obligatoire + cohérence genre ----------------------------
CREATE OR REPLACE FUNCTION private.rpc_create_battle(
  p_title         text,
  p_slug          text,
  p_producer2_id  uuid,
  p_description   text DEFAULT NULL,
  p_product1_id   uuid DEFAULT NULL,
  p_product2_id   uuid DEFAULT NULL,
  p_battle_type   text DEFAULT 'user',
  p_genre_id      uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor          uuid := auth.uid();
  v_title          text := NULLIF(trim(COALESCE(p_title, '')), '');
  v_slug           text := NULLIF(trim(COALESCE(p_slug, '')), '');
  v_description    text := NULLIF(trim(COALESCE(p_description, '')), '');
  v_cooldown_days  integer;
  v_cooldown_end   timestamptz;
  v_new_battle_id  uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = '42501';
  END IF;

  IF v_title IS NULL THEN
    RAISE EXCEPTION 'title_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_slug IS NULL THEN
    RAISE EXCEPTION 'slug_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_battle_type IS NULL OR p_battle_type NOT IN ('user') THEN
    RAISE EXCEPTION 'unsupported_battle_type' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.is_battle_genre_eligible(p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_GENRE_INVALID'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('genre_id', p_genre_id)::text;
  END IF;

  -- product1 (beat du créateur) obligatoire
  IF p_product1_id IS NULL THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_REQUIRED' USING ERRCODE = 'P0001';
  END IF;

  -- cohérence de genre du beat du créateur
  IF NOT public.is_battle_product_genre_match(p_product1_id, p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT1_GENRE_MISMATCH'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('product1_id', p_product1_id, 'genre_id', p_genre_id)::text;
  END IF;

  -- product2 reste optionnel à la création, mais s'il est fourni il doit matcher le genre
  IF p_product2_id IS NOT NULL
     AND NOT public.is_battle_product_genre_match(p_product2_id, p_genre_id) THEN
    RAISE EXCEPTION 'BATTLE_PRODUCT2_GENRE_MISMATCH'
      USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('product2_id', p_product2_id, 'genre_id', p_genre_id)::text;
  END IF;

  PERFORM public.assert_battle_create_validations(
    v_actor,
    p_producer2_id,
    p_product1_id,
    p_product2_id,
    false,
    400
  );

  PERFORM public.assert_battle_product_monthly_caps(
    p_product1_id,
    p_product2_id,
    NULL
  );

  v_cooldown_days := public.get_battle_pair_cooldown_days(p_battle_type);

  IF NOT public.can_create_battle(v_actor) THEN
    RAISE EXCEPTION 'BATTLE_QUOTA_REACHED' USING ERRCODE = 'P0001';
  END IF;

  IF NOT public.can_create_active_battle(v_actor) THEN
    RAISE EXCEPTION 'BATTLE_ACTIVE_CAP_REACHED' USING ERRCODE = 'P0001';
  END IF;

  IF public.check_battle_pair_active(v_actor, p_producer2_id) THEN
    RAISE EXCEPTION 'BATTLE_PAIR_ALREADY_ACTIVE' USING ERRCODE = 'P0002';
  END IF;

  v_cooldown_end := public.get_battle_pair_cooldown_end(
    v_actor,
    p_producer2_id
  );

  IF v_cooldown_end IS NOT NULL THEN
    RAISE EXCEPTION 'BATTLE_PAIR_COOLDOWN'
      USING ERRCODE = 'P0003',
            DETAIL = jsonb_build_object(
              'cooldown_end_at', to_char(v_cooldown_end AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
              'cooldown_days',   v_cooldown_days,
              'opponent_id',     p_producer2_id
            )::text;
  END IF;

  INSERT INTO public.battles (
    title,
    slug,
    description,
    producer1_id,
    producer2_id,
    product1_id,
    product2_id,
    genre_id,
    status,
    winner_id,
    votes_producer1,
    votes_producer2
  )
  VALUES (
    v_title,
    v_slug,
    v_description,
    v_actor,
    p_producer2_id,
    p_product1_id,
    p_product2_id,
    p_genre_id,
    'pending_acceptance',
    NULL,
    0,
    0
  )
  RETURNING id INTO v_new_battle_id;

  RETURN v_new_battle_id;
END;
$$;

-- 3) Acceptation avec beat -------------------------------------------------------
DROP FUNCTION IF EXISTS public.respond_to_battle(uuid, boolean, text);

CREATE FUNCTION public.respond_to_battle(
  p_battle_id   uuid,
  p_accept      boolean,
  p_reason      text DEFAULT NULL,
  p_product2_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_battle public.battles%ROWTYPE;
  v_reason text := NULLIF(trim(COALESCE(p_reason, '')), '');
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'auth_required';
  END IF;

  SELECT * INTO v_battle
  FROM public.battles
  WHERE id = p_battle_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'battle_not_found';
  END IF;

  IF v_battle.producer2_id IS NULL OR v_battle.producer2_id != v_actor THEN
    RAISE EXCEPTION 'only_invited_producer_can_respond';
  END IF;

  IF v_battle.status != 'pending_acceptance' THEN
    RAISE EXCEPTION 'battle_not_waiting_for_response';
  END IF;

  IF v_battle.accepted_at IS NOT NULL OR v_battle.rejected_at IS NOT NULL THEN
    RAISE EXCEPTION 'response_already_recorded';
  END IF;

  IF p_accept THEN
    -- Beat désormais obligatoire pour accepter
    IF p_product2_id IS NULL THEN
      RAISE EXCEPTION 'BATTLE_PRODUCT2_REQUIRED' USING ERRCODE = 'P0001';
    END IF;

    -- Cohérence de genre avec la battle
    IF NOT public.is_battle_product_genre_match(p_product2_id, v_battle.genre_id) THEN
      RAISE EXCEPTION 'BATTLE_PRODUCT2_GENRE_MISMATCH'
        USING ERRCODE = 'P0001',
              DETAIL = jsonb_build_object('product2_id', p_product2_id, 'genre_id', v_battle.genre_id)::text;
    END IF;

    -- Rejoue exactement la validation admin (producteurs actifs, écart Elo,
    -- les 2 beats requis + éligibles). product2 est vérifié pour v_actor.
    PERFORM public.assert_battle_create_validations(
      v_battle.producer1_id,
      v_actor,
      v_battle.product1_id,
      p_product2_id,
      true,
      400
    );

    -- Cap mensuel produit (exclut la battle courante du décompte)
    PERFORM public.assert_battle_product_monthly_caps(
      NULL,
      p_product2_id,
      p_battle_id
    );

    -- Attache le beat + avance. Le trigger trg_sync_battle_product_locks_write
    -- se déclenche ici et lève BATTLE_PRODUCT_ALREADY_OCCUPIED si déjà engagé.
    UPDATE public.battles
    SET product2_id = p_product2_id,
        status = 'awaiting_admin',
        accepted_at = now(),
        rejected_at = NULL,
        rejection_reason = NULL,
        updated_at = now()
    WHERE id = p_battle_id;
  ELSE
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;

    IF NOT public.check_daily_battle_refusals(v_actor) THEN
      RAISE EXCEPTION 'Daily battle refusal limit reached (5 per day)';
    END IF;

    UPDATE public.battles
    SET status = 'rejected',
        rejected_at = now(),
        accepted_at = NULL,
        rejection_reason = v_reason,
        updated_at = now()
    WHERE id = p_battle_id;

    UPDATE public.user_profiles
    SET battle_refusal_count = COALESCE(battle_refusal_count, 0) + 1,
        updated_at = now()
    WHERE id = v_actor;

    PERFORM public.recalculate_engagement(v_actor);
  END IF;

  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_battle(uuid, boolean, text, uuid) TO authenticated;

COMMIT;
```

- [ ] **Step 2: Appliquer la migration sur une base de test (branche Supabase ou local)**

Préférer une branche/preview, PAS la prod directement. Local :
Run: `supabase db reset` (recharge toutes les migrations sur la base locale)
Expected: se termine sans erreur, la nouvelle migration est listée dans la sortie.

> Si pas de stack local : appliquer sur une branche Supabase de dev. Ne JAMAIS tester en prod.

- [ ] **Step 3: Vérifier les signatures et le helper**

Run (psql sur la base de test) :
```sql
SELECT proname, pg_get_function_arguments(oid)
FROM pg_proc
WHERE proname IN ('respond_to_battle','is_battle_product_genre_match')
  AND pronamespace = 'public'::regnamespace
ORDER BY proname;
```
Expected :
- `respond_to_battle | p_battle_id uuid, p_accept boolean, p_reason text DEFAULT NULL, p_product2_id uuid DEFAULT NULL`
- `is_battle_product_genre_match | p_product_id uuid, p_genre_id uuid`
- (une SEULE ligne `respond_to_battle` — l'ancienne 3-args ne doit plus exister)

- [ ] **Step 4: Vérifier le comportement métier (assertions SQL)**

Run (psql, en remplaçant les UUID par des données de test réelles de la base) :
```sql
-- a) accept sans beat -> BATTLE_PRODUCT2_REQUIRED
-- b) accept avec beat d'un autre genre -> BATTLE_PRODUCT2_GENRE_MISMATCH
-- c) création sans product1 -> BATTLE_PRODUCT1_REQUIRED
-- (exécuter chaque RPC dans une session authentifiée comme le bon producteur ;
--  vérifier le message d'exception levé)
SELECT public.is_battle_product_genre_match(
  '<beat_id_du_genre_X>'::uuid, '<genre_X_id>'::uuid);  -- attendu: t
SELECT public.is_battle_product_genre_match(
  '<beat_id_du_genre_X>'::uuid, '<genre_Y_id>'::uuid);  -- attendu: f
```
Expected : les messages d'exception correspondent aux codes attendus ; le helper renvoie `t`/`f` correctement.

- [ ] **Step 5: Commit**

```bash
git add "supabase/migrations/20260624120000_battle_accept_with_beat.sql"
git commit -m "feat(db): respond_to_battle accepte un beat + product1 requis + cohérence genre

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Régénérer les types TypeScript

**Files:**
- Modify: `src/lib/supabase/database.types.ts`

**Interfaces:**
- Consumes : la migration de Task 1 appliquée sur la base **liée** (`--linked`).
- Produces : `Database['public']['Functions']['respond_to_battle']['Args']` inclut `p_product2_id?: string`.

- [ ] **Step 1: Générer les types depuis la base liée**

Run: `npm run supabase:types`
Expected: `Types generated successfully` et aucun diff inattendu hors fonctions battle.

> Prérequis : la migration de Task 1 doit être appliquée sur la base ciblée par `--linked`. Si la base liée est la prod, attendre le déploiement de Task 7 puis régénérer, OU générer depuis une branche de dev liée.

- [ ] **Step 2: Vérifier le diff de types**

Run: `git diff src/lib/supabase/database.types.ts`
Expected: dans `respond_to_battle.Args`, présence de `p_product2_id?: string` (en plus de `p_battle_id`, `p_accept`, `p_reason?`). `rpc_create_battle.Args` inchangé.

- [ ] **Step 3: Typecheck**

Run: `npm run typecheck`
Expected: PASS (0 erreur).

- [ ] **Step 4: Commit**

```bash
git add src/lib/supabase/database.types.ts
git commit -m "chore(types): regen database.types after respond_to_battle p_product2_id

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Front — plomberie données (ProductOption, myProducts, IncomingBattle genre)

**Files:**
- Modify: `src/pages/ProducerBattles.tsx`

**Interfaces:**
- Produces : `ProductOption` porte `is_published`, `status`, `product_type` ; `IncomingBattle` porte `genre_id` ; `myProducts` et la requête `incomingRes` les renvoient. Consommé par Task 4 et Task 5.

- [ ] **Step 1: Étendre l'interface `ProductOption`**

Dans `src/pages/ProducerBattles.tsx`, remplacer le bloc (≈ lignes 23-27) :
```ts
interface ProductOption {
  id: string;
  title: string;
  genre_id: string | null;
}
```
par :
```ts
interface ProductOption {
  id: string;
  title: string;
  genre_id: string | null;
  is_published: boolean | null;
  status: string | null;
  product_type: string | null;
}
```

- [ ] **Step 2: Ajouter `genre_id` à l'interface `IncomingBattle`**

Remplacer le bloc (≈ lignes 45-54) :
```ts
interface IncomingBattle {
  id: string;
  title: string;
  slug: string;
  status: BattleStatus;
  response_deadline: string | null;
  producer1?: { username: string | null };
  product1?: { title: string };
  product2?: { title: string };
}
```
par :
```ts
interface IncomingBattle {
  id: string;
  title: string;
  slug: string;
  status: BattleStatus;
  response_deadline: string | null;
  genre_id: string | null;
  producer1?: { username: string | null };
  product1?: { title: string };
  product2?: { title: string };
}
```

- [ ] **Step 3: Étendre le `select` de `myProducts`**

Dans `loadInitial` (≈ ligne 730-735), remplacer :
```ts
        supabase
          .from('products')
          .select('id, title, genre_id')
          .eq('producer_id', profile.id)
          .is('deleted_at', null)
          .order('created_at', { ascending: false }),
```
par :
```ts
        supabase
          .from('products')
          .select('id, title, genre_id, is_published, status, product_type')
          .eq('producer_id', profile.id)
          .is('deleted_at', null)
          .order('created_at', { ascending: false }),
```

- [ ] **Step 4: Ajouter `genre_id` au `select` de la requête `incomingRes`**

Dans `loadBattles` (≈ lignes 516-527), dans le 2ᵉ `select` (celui filtré `.eq('producer2_id', profile.id)`), ajouter `genre_id,` après `response_deadline,` :
```ts
      supabase
        .from('battles')
        .select(`
          id,
          title,
          slug,
          status,
          response_deadline,
          genre_id,
          producer1:user_profiles!battles_producer1_id_fkey(username),
          product1:products!battles_product1_id_fkey(title),
          product2:products!battles_product2_id_fkey(title)
        `)
        .eq('producer2_id', profile.id)
        .eq('status', 'pending_acceptance')
        .order('created_at', { ascending: false }),
```

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: PASS. (Le `producer2Products` select ne renvoie pas encore les nouveaux champs — voir note ci-dessous, ce n'est pas bloquant car ces options ne lisent que `id/title/genre_id`.)

> Note : `loadProducer2Products` (≈ ligne 808) garde `select('id, title, genre_id')`. Les objets en sortie sont castés `ProductOption`, donc les champs ajoutés sont `undefined` — acceptable car ce flux (création par P1) ne filtre pas sur l'éligibilité de l'adversaire. Ne PAS modifier ce select.

- [ ] **Step 6: Commit**

```bash
git add src/pages/ProducerBattles.tsx
git commit -m "feat(battles): expose product eligibility fields + incoming battle genre

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Front — création : product1 obligatoire + sélecteur limité aux beats éligibles

**Files:**
- Modify: `src/pages/ProducerBattles.tsx`

**Interfaces:**
- Consumes : `ProductOption` étendu (Task 3), helpers i18n existants.
- Produces : `createBattle` bloque sans product1 ; `product1Options` ne liste que des beats éligibles du genre choisi.

- [ ] **Step 1: Restreindre `product1Options` aux beats éligibles**

Remplacer le `useMemo` `product1Options` (≈ lignes 375-392) par :
```ts
  const product1Options = useMemo(
    () => [
      { value: '', label: t('producerBattles.chooseProduct') },
      ...myProducts
        .filter(
          (p) =>
            p.product_type === 'beat' &&
            p.is_published === true &&
            p.status === 'active'
        )
        .filter((p) => !form.genreId || p.genre_id === form.genreId)
        .map((p) => {
          const occupied = occupiedProductIds.has(p.id);
          return {
            value: p.id,
            label: occupied
              ? `${p.title} ${t('producerBattles.productOccupiedOptionSuffix')}`
              : p.title,
            disabled: occupied,
          };
        }),
    ],
    [form.genreId, myProducts, occupiedProductIds, t]
  );
```

- [ ] **Step 2: Exiger product1 dans `createBattle`**

Dans `createBattle`, juste après le bloc qui vérifie `form.genreId` (≈ lignes 869-872), ajouter :
```ts
    if (!form.product1Id) {
      setError(t('producerBattles.product1Required'));
      return;
    }
```

- [ ] **Step 3: Désactiver le bouton de création sans product1**

Localiser le bouton de soumission du formulaire de création (chercher l'appel `onClick={createBattle}` ou `onClick={() => createBattle()}` dans le JSX, ≈ après la ligne 1226). Ajouter `!form.product1Id` à sa condition `disabled`. Exemple : si le bouton est
```tsx
<Button onClick={createBattle} isLoading={isSaving} disabled={isSaving || !canCreateBattle}>
```
le remplacer par
```tsx
<Button onClick={createBattle} isLoading={isSaving} disabled={isSaving || !canCreateBattle || !form.product1Id}>
```
(Adapter à la condition existante réelle ; ajouter `|| !form.product1Id`.)

- [ ] **Step 4: Mapper les erreurs création (product1) dans `toBattleInsertErrorMessage`**

Dans `toBattleInsertErrorMessage`, juste avant le bloc `BATTLE_PRODUCER1_NOT_ACTIVE` (≈ ligne 235), ajouter :
```ts
  if (message.includes('BATTLE_PRODUCT1_REQUIRED')) {
    return t('producerBattles.product1Required');
  }

  if (message.includes('BATTLE_PRODUCT1_GENRE_MISMATCH')) {
    return t('producerBattles.product1GenreMismatchError');
  }

  if (message.includes('BATTLE_PRODUCT2_GENRE_MISMATCH')) {
    return t('producerBattles.product2GenreMismatchError');
  }
```

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: PASS. (Les clés i18n `product1Required`, `product1GenreMismatchError`, `product2GenreMismatchError` sont ajoutées en Task 6 ; `t()` accepte n'importe quelle string donc pas d'erreur de type ici.)

- [ ] **Step 6: Commit**

```bash
git add src/pages/ProducerBattles.tsx
git commit -m "feat(battles): require creator beat (product1) at battle creation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Front — acceptation : afficher le genre + sélecteur de beat + envoi de product2

**Files:**
- Modify: `src/pages/ProducerBattles.tsx`

**Interfaces:**
- Consumes : `IncomingBattle.genre_id` (Task 3), `ProductOption` étendu, `myProducts`, `occupiedProductIds`, `genres`, `getLocalizedName`, `language`, `respondToBattle`.
- Produces : `respondToBattle(battleId, accept, product2Id?)` ; état `acceptBeatByBattle`.

- [ ] **Step 1: Ajouter l'état du beat sélectionné par invitation**

Juste après la déclaration `const [rejectReasons, setRejectReasons] = useState<Record<string, string>>({});` (≈ ligne 339), ajouter :
```ts
  const [acceptBeatByBattle, setAcceptBeatByBattle] = useState<Record<string, string>>({});
```

- [ ] **Step 2: Helper d'options de beat pour un genre donné**

Ajouter, à proximité des `useMemo` d'options (après `product2Options`, ≈ ligne 409), une fonction membre du composant :
```ts
  const buildAcceptBeatOptions = (genreId: string | null) => [
    { value: '', label: t('producerBattles.chooseProduct') },
    ...myProducts
      .filter(
        (p) =>
          p.product_type === 'beat' &&
          p.is_published === true &&
          p.status === 'active'
      )
      .filter((p) => !genreId || p.genre_id === genreId)
      .map((p) => {
        const occupied = occupiedProductIds.has(p.id);
        return {
          value: p.id,
          label: occupied
            ? `${p.title} ${t('producerBattles.productOccupiedOptionSuffix')}`
            : p.title,
          disabled: occupied,
        };
      }),
  ];
```

- [ ] **Step 3: Faire passer product2 dans `respondToBattle`**

Remplacer la signature et l'appel RPC de `respondToBattle` (≈ lignes 929-944). Nouvelle version :
```ts
  const respondToBattle = async (battleId: string, accept: boolean, product2Id?: string) => {
    setError(null);

    const reason = (rejectReasons[battleId] || '').trim();
    if (!accept && !reason) {
      setError(t('producerBattles.rejectionReasonRequired'));
      return;
    }
    if (accept && !product2Id) {
      setError(t('producerBattles.acceptBeatRequired'));
      return;
    }

    setRespondingId(battleId);

    const { error: rpcError } = await supabase.rpc('respond_to_battle', {
      p_battle_id: battleId,
      p_accept: accept,
      p_reason: accept ? undefined : reason,
      p_product2_id: accept ? product2Id : undefined,
    });
```
(Le reste de la fonction — gestion d'erreur, `setRejectReasons`, `trackJoinBattle`, `loadBattles` — reste identique.)

- [ ] **Step 4: Réinitialiser le beat choisi après une réponse réussie**

Dans `respondToBattle`, juste après `setRejectReasons((prev) => ({ ...prev, [battleId]: '' }));` (≈ ligne 959), ajouter :
```ts
    setAcceptBeatByBattle((prev) => ({ ...prev, [battleId]: '' }));
```

- [ ] **Step 5: Rendre le genre + sélecteur + lien upload dans la carte d'invitation**

Dans le `incomingBattles.map((battle) => ...)` (≈ lignes 1376-1427), remplacer le bloc `<div className="space-y-2"> ... </div>` qui contient l'`Input` de raison et les boutons (≈ lignes 1394-1426) par :
```tsx
                  {(() => {
                    const beatOptions = buildAcceptBeatOptions(battle.genre_id);
                    const hasEligibleBeat = beatOptions.length > 1;
                    const genre = genres.find((g) => g.id === battle.genre_id);
                    const genreName = genre ? getLocalizedName(genre, language) : null;
                    const selectedBeat = acceptBeatByBattle[battle.id] || '';
                    return (
                      <div className="space-y-2">
                        {genreName && (
                          <p className="text-xs text-emerald-400">
                            {t('producerBattles.battleGenreLabel', { genre: genreName })}
                          </p>
                        )}

                        {hasEligibleBeat ? (
                          <Select
                            label={t('producerBattles.acceptBeatLabel')}
                            value={selectedBeat}
                            onChange={(event) =>
                              setAcceptBeatByBattle((prev) => ({
                                ...prev,
                                [battle.id]: event.target.value,
                              }))
                            }
                            options={beatOptions}
                          />
                        ) : (
                          <div className="text-sm text-amber-400 space-y-2">
                            <p>
                              {t('producerBattles.noEligibleBeatForGenre', {
                                genre: genreName || '',
                              })}
                            </p>
                            <Link
                              to="/producer/upload"
                              className="inline-flex items-center gap-1 text-emerald-400 underline"
                            >
                              {t('producerBattles.uploadBeatCta')}
                            </Link>
                          </div>
                        )}

                        <Input
                          label={t('producerBattles.rejectionReasonLabel')}
                          value={rejectReasons[battle.id] || ''}
                          onChange={(event) =>
                            setRejectReasons((prev) => ({
                              ...prev,
                              [battle.id]: event.target.value,
                            }))
                          }
                          placeholder={t('producerBattles.rejectionReasonPlaceholder')}
                        />
                        <div className="flex flex-wrap gap-2 justify-end">
                          <Button
                            size="sm"
                            variant="outline"
                            isLoading={respondingId === battle.id}
                            disabled={!selectedBeat || respondingId === battle.id}
                            leftIcon={<CheckCircle2 className="w-4 h-4" />}
                            onClick={() => respondToBattle(battle.id, true, selectedBeat)}
                          >
                            {t('producerBattles.accept')}
                          </Button>
                          <Button
                            size="sm"
                            variant="danger"
                            isLoading={respondingId === battle.id}
                            leftIcon={<XCircle className="w-4 h-4" />}
                            onClick={() => respondToBattle(battle.id, false)}
                          >
                            {t('producerBattles.reject')}
                          </Button>
                        </div>
                      </div>
                    );
                  })()}
```

- [ ] **Step 6: S'assurer que `Link` est importé**

Vérifier en haut de `src/pages/ProducerBattles.tsx` la présence de `import { Link } from 'react-router-dom';`.
Run: `grep -n "react-router-dom" src/pages/ProducerBattles.tsx`
Si `Link` n'est pas importé, l'ajouter à l'import existant de `react-router-dom` (ou créer l'import). Vérifier aussi que `getLocalizedName` et `language` sont déjà disponibles dans le composant (ils le sont — utilisés par `genreOptions`).

- [ ] **Step 7: Ajouter les mappings d'erreur acceptation dans `toRpcErrorMessage`**

Dans `toRpcErrorMessage`, juste avant le `return t('producerBattles.actionUnavailable', { technical });` final (≈ ligne 151), ajouter :
```ts
  if (message.includes('BATTLE_PRODUCT2_REQUIRED')) return t('producerBattles.acceptBeatRequired');
  if (message.includes('BATTLE_PRODUCT2_GENRE_MISMATCH')) return t('producerBattles.product2GenreMismatchError');
  if (message.includes('BATTLE_PRODUCT2_INVALID')) return t('producerBattles.product2InvalidError');
  if (message.includes('BATTLE_PRODUCT_ALREADY_OCCUPIED')) return t('producerBattles.productAlreadyOccupiedError');
  if (message.includes('BATTLE_PRODUCT1_INVALID')) return t('producerBattles.product1InvalidError');
  if (message.includes('BATTLE_PRODUCER1_NOT_ACTIVE')) return t('producerBattles.producer1NotActiveError');
```

- [ ] **Step 8: Typecheck**

Run: `npm run typecheck`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/pages/ProducerBattles.tsx
git commit -m "feat(battles): accept invitation by selecting a beat in the battle genre

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: i18n — nouvelles clés dans les 4 langues

**Files:**
- Modify: `src/lib/i18n/translations/fr.ts`
- Modify: `src/lib/i18n/translations/en.ts`
- Modify: `src/lib/i18n/translations/es.ts`
- Modify: `src/lib/i18n/translations/de.ts`

**Interfaces:**
- Consumes : clés référencées en Task 4/5.
- Produces : clés `product1Required`, `product1GenreMismatchError`, `product2GenreMismatchError`, `product2InvalidError`, `product1InvalidError`, `acceptBeatLabel`, `acceptBeatRequired`, `battleGenreLabel`, `noEligibleBeatForGenre`, `uploadBeatCta` sous `producerBattles:`.

- [ ] **Step 1: Ajouter les clés FR**

Dans `src/lib/i18n/translations/fr.ts`, dans le bloc `producerBattles: {` (≈ ligne 746), ajouter ces lignes (par ex. juste après `chooseGenre`) :
```ts
    product1Required: 'Selectionne ton beat pour lancer la demande.',
    product1GenreMismatchError: 'Ton beat doit etre dans le style choisi pour la battle.',
    product2GenreMismatchError: 'Ce beat n\'est pas dans le style demande pour cette battle.',
    product2InvalidError: 'Ce beat n\'est pas eligible (il doit etre un beat publie et actif).',
    product1InvalidError: 'Le beat du createur n\'est plus disponible pour cette battle.',
    acceptBeatLabel: 'Ton beat pour cette battle',
    acceptBeatRequired: 'Choisis un beat pour accepter cette battle.',
    battleGenreLabel: 'Battle demandee en : {genre}',
    noEligibleBeatForGenre: 'Tu n\'as pas de beat en {genre}. Uploade un beat dans ce style, ou refuse la demande.',
    uploadBeatCta: 'Uploader un beat',
```

- [ ] **Step 2: Ajouter les clés EN**

Dans `src/lib/i18n/translations/en.ts`, bloc `producerBattles: {` :
```ts
    product1Required: 'Select your beat to send the challenge.',
    product1GenreMismatchError: 'Your beat must be in the battle genre.',
    product2GenreMismatchError: 'This beat is not in the requested battle genre.',
    product2InvalidError: 'This beat is not eligible (it must be a published, active beat).',
    product1InvalidError: 'The challenger\'s beat is no longer available for this battle.',
    acceptBeatLabel: 'Your beat for this battle',
    acceptBeatRequired: 'Pick a beat to accept this battle.',
    battleGenreLabel: 'Battle requested in: {genre}',
    noEligibleBeatForGenre: 'You have no beat in {genre}. Upload a beat in this genre, or decline.',
    uploadBeatCta: 'Upload a beat',
```

- [ ] **Step 3: Ajouter les clés ES**

Dans `src/lib/i18n/translations/es.ts`, bloc `producerBattles: {` :
```ts
    product1Required: 'Selecciona tu beat para enviar el reto.',
    product1GenreMismatchError: 'Tu beat debe ser del estilo de la batalla.',
    product2GenreMismatchError: 'Este beat no es del estilo solicitado para la batalla.',
    product2InvalidError: 'Este beat no es elegible (debe ser un beat publicado y activo).',
    product1InvalidError: 'El beat del retador ya no esta disponible para esta batalla.',
    acceptBeatLabel: 'Tu beat para esta batalla',
    acceptBeatRequired: 'Elige un beat para aceptar esta batalla.',
    battleGenreLabel: 'Batalla solicitada en: {genre}',
    noEligibleBeatForGenre: 'No tienes ningun beat en {genre}. Sube un beat de este estilo o rechaza.',
    uploadBeatCta: 'Subir un beat',
```

- [ ] **Step 4: Ajouter les clés DE**

Dans `src/lib/i18n/translations/de.ts`, bloc `producerBattles: {` :
```ts
    product1Required: 'Wahle deinen Beat, um die Anfrage zu senden.',
    product1GenreMismatchError: 'Dein Beat muss im Genre der Battle sein.',
    product2GenreMismatchError: 'Dieser Beat ist nicht im angefragten Battle-Genre.',
    product2InvalidError: 'Dieser Beat ist nicht zulassig (er muss ein veroffentlichter, aktiver Beat sein).',
    product1InvalidError: 'Der Beat des Herausforderers ist fur diese Battle nicht mehr verfugbar.',
    acceptBeatLabel: 'Dein Beat fur diese Battle',
    acceptBeatRequired: 'Wahle einen Beat, um diese Battle anzunehmen.',
    battleGenreLabel: 'Battle angefragt in: {genre}',
    noEligibleBeatForGenre: 'Du hast keinen Beat in {genre}. Lade einen Beat in diesem Genre hoch oder lehne ab.',
    uploadBeatCta: 'Beat hochladen',
```

- [ ] **Step 5: Typecheck + lint**

Run: `npm run typecheck && npm run lint`
Expected: PASS (toutes les clés `t('producerBattles.*')` désormais présentes ; pas d'erreur de virgule/structure dans les fichiers de traduction).

- [ ] **Step 6: Commit**

```bash
git add src/lib/i18n/translations/fr.ts src/lib/i18n/translations/en.ts src/lib/i18n/translations/es.ts src/lib/i18n/translations/de.ts
git commit -m "i18n(battles): accept-with-beat strings in 4 languages

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Vérification end-to-end + déploiement

**Files:** (aucun nouveau fichier — vérification et déploiement)

- [ ] **Step 1: Build complet**

Run: `npm run build`
Expected: build Vite réussi, 0 erreur TypeScript.

- [ ] **Step 2: Test manuel du cycle complet (sur env de dev)**

Avec deux comptes producteurs actifs (P1 avec un beat publié en genre X ; P2 sans beat) :
1. P1 crée une battle en genre X → impossible sans sélectionner son beat (bouton désactivé / message `product1Required`). Avec beat → demande créée.
2. P2 ouvre « Invitations reçues » → voit « Battle demandée en : X », et soit un sélecteur de ses beats X, soit le message + lien « Uploader un beat » s'il n'en a pas.
3. P2 sans beat X → uploade un beat en genre X via `/producer/upload`, revient, le beat apparaît dans le sélecteur.
4. P2 sélectionne le beat et accepte → la battle passe en `awaiting_admin` avec `product2_id` rempli.
5. Admin valide → battle `active` (plus de blocage `BATTLE_PRODUCT2_REQUIRED`).
6. Cas d'erreur : P2 tente d'accepter avec un beat déjà engagé ailleurs → message `productAlreadyOccupiedError`.

Expected: chaque étape se comporte comme décrit ; messages d'erreur lisibles dans la langue active.

- [ ] **Step 3: Vérifier les battles historiques bloquées (requête de contrôle)**

Run (psql sur la base ciblée) :
```sql
SELECT id, title, status, product1_id, product2_id, created_at
FROM public.battles
WHERE status = 'awaiting_admin'
  AND (product1_id IS NULL OR product2_id IS NULL)
ORDER BY created_at;
```
Expected: lister ces battles « legacy » ; elles ne sont PAS migrées automatiquement → à annuler côté admin. Communiquer la liste.

- [ ] **Step 4: Déploiement**

- Fusionner vers `main`/prod selon le process habituel du repo.
- Appliquer la migration : `supabase db push` (file-based, respecte l'ordre). Si MCP `apply_migration` est utilisé à la place, **réaligner `schema_migrations.version`** ensuite.
- Régénérer les types contre la prod si Task 2 a été faite sur une branche : `npm run supabase:types`, recommit si diff.
Expected: migration appliquée, `respond_to_battle` 4-args en prod, front déployé.

- [ ] **Step 5: Smoke test prod**

Refaire le cœur de l'étape 2 (créer → accepter avec beat → valider admin) avec des comptes de test en prod.
Expected: cycle complet OK.

---

## Self-Review (effectuée)

**Couverture spec :** problème (Task 1+5) · beat obligatoire pour accepter (Task 1 step1 `BATTLE_PRODUCT2_REQUIRED` + Task 5 garde front) · product1 obligatoire création (Task 1 `private.rpc_create_battle` + Task 4) · cohérence genre 2 côtés (helper Task 1 + checks création/accept) · sélection beat existant filtré genre + occupés grisés (Task 5) · lien upload si aucun beat (Task 5) · anti-occupation via trigger (Task 1 UPDATE) · i18n 4 langues (Task 6) · types (Task 2) · tests/déploiement (Task 7). ✓

**Placeholders :** aucun « TBD/TODO » ; le seul point adaptatif est le bouton de création (Task 4 step 3) dont la condition `disabled` réelle doit être complétée par `|| !form.product1Id` (instruction explicite donnée). ✓

**Cohérence des noms :** `p_product2_id` (DB) ↔ `p_product2_id` (appel RPC front) ; `acceptBeatByBattle` / `setAcceptBeatByBattle` ; `buildAcceptBeatOptions` ; clés i18n identiques entre Task 4/5 (usage) et Task 6 (définition) : `product1Required`, `product1GenreMismatchError`, `product2GenreMismatchError`, `product2InvalidError`, `product1InvalidError`, `acceptBeatLabel`, `acceptBeatRequired`, `battleGenreLabel`, `noEligibleBeatForGenre`, `uploadBeatCta`. ✓
