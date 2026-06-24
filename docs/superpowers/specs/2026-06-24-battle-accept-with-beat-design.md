# Spec — Accepter une battle avec son beat (producteur 2)

**Date :** 2026-06-24
**Statut :** Design validé, en attente de relecture utilisateur avant plan d'implémentation
**Auteur :** Ludovic + Claude

---

## 1. Problème

Aujourd'hui, une demande de battle peut être créée même si le producteur adverse (producteur 2)
n'a aucun beat sélectionné. Mais elle ne peut jamais devenir une vraie battle active :

1. **Création** — `rpc_create_battle` valide avec `p_require_products = false` et insère la battle
   en `pending_acceptance` avec `product2_id` (et même `product1_id`) potentiellement `NULL`.
2. **Acceptation** — `respond_to_battle(p_battle_id, p_accept, p_reason)` ne prend **aucun beat** ;
   sur accept, elle passe juste `pending_acceptance` → `awaiting_admin`. Le beat du producteur 2
   n'est jamais attaché.
3. **Validation admin** — relance la validation avec `p_require_products = true`. Si `product2_id`
   est `NULL` → `BATTLE_PRODUCT2_REQUIRED`. **Blocage définitif** en `awaiting_admin`.

Conséquence : le producteur 2 peut uploader un beat *après* la création, mais ce beat ne se
rattache jamais automatiquement à la demande existante. La seule issue actuelle est d'annuler /
refuser puis recréer la battle.

## 2. Objectif

Permettre de défier un producteur **sans beat**. Au moment de répondre, le producteur 2
**choisit un de ses beats existants** (uploadé au préalable, dans le bon style) pour valider
l'acceptation, ou il **refuse**. Plus aucune battle ne reste bloquée faute de beat.

### Règles métier validées

1. **Beat obligatoire pour accepter** — le producteur 2 ne peut plus accepter sans beat ; il peut
   seulement accepter-avec-beat ou refuser.
2. **product1 obligatoire à la création** — le créateur doit présenter son propre beat. Combiné à
   la règle 1, toute battle acceptée a forcément ses 2 beats → plus de blocage en `awaiting_admin`.
3. **Cohérence de genre** — la battle a un genre de référence (`battles.genre_id`). Le beat du
   producteur 1 (à la création) ET celui du producteur 2 (à l'acceptation) doivent appartenir à
   ce **même genre**. Le producteur 2 est informé du style demandé ; s'il n'a pas de beat dans ce
   style, il uploade ou il refuse.
4. **Sélection d'un beat existant** (pas d'upload inline) — réutilise la page d'upload existante.

### Hors périmètre (non-goals)

- Pas d'upload de beat directement dans la fenêtre d'acceptation (sélection d'existant uniquement).
- Pas de modification du flux de refus (raison obligatoire, quota 5 refus/jour) — inchangé.
- Pas de changement du cap de battles actives, ni des quotas mensuels existants.
- Pas de migration de données : les battles déjà bloquées en `awaiting_admin` sans `product2`
  restent à traiter manuellement (annulation admin) — voir §9.

## 3. Décision d'architecture

**Étendre `respond_to_battle` avec un paramètre optionnel `p_product2_id`** qui valide et attache
le beat dans le même appel atomique.

Alternatives écartées :
- RPC séparé `attach_battle_beat` + `respond_to_battle` inchangée → 2 appels non atomiques, plus de
  surface de bug.
- Rendre product2 obligatoire à la création → impossible, le créateur ne possède pas le beat de
  l'adversaire.

## 4. Changements base de données

Une **nouvelle migration** `supabase/migrations/20260624XXXXXX_battle_accept_with_beat.sql`
(timestamp **postérieur** à `20260624073000`, dont elle dépend pour la version canonique de
`assert_battle_create_validations`).

### 4.1 `respond_to_battle` — nouveau paramètre `p_product2_id`

Définition actuelle :
`supabase/migrations/20260307113000_add_battle_limits_and_refusal_protection.sql:98`
```sql
respond_to_battle(p_battle_id uuid, p_accept boolean, p_reason text DEFAULT NULL) RETURNS boolean
```

> **Important :** ajouter un 4ᵉ paramètre crée une *surcharge*. Il faut d'abord
> `DROP FUNCTION public.respond_to_battle(uuid, boolean, text);` puis `CREATE` la nouvelle
> version, sinon l'ancienne signature 3-args subsiste et permettrait encore d'accepter sans beat
> (réintroduction du bug).

Nouvelle définition :
```sql
respond_to_battle(
  p_battle_id  uuid,
  p_accept     boolean,
  p_reason     text DEFAULT NULL,
  p_product2_id uuid DEFAULT NULL
) RETURNS boolean
```

Logique sur **accept** (`p_accept = true`), après les contrôles existants
(acteur = producteur 2, statut `pending_acceptance`, pas de réponse déjà enregistrée) :

1. Si `p_product2_id IS NULL` → `RAISE EXCEPTION 'BATTLE_PRODUCT2_REQUIRED'`.
2. **Éligibilité** : `IF NOT public.is_battle_product_eligible(p_product2_id, v_actor) THEN RAISE
   'BATTLE_PRODUCT2_INVALID'` (vérifie : beat appartenant à l'acteur, `product_type='beat'`,
   `status='active'`, `is_published=true`, non supprimé).
3. **Cohérence de genre** : si `v_battle.genre_id IS NOT NULL` et que le `genre_id` du beat ≠
   `v_battle.genre_id` → `RAISE 'BATTLE_PRODUCT2_GENRE_MISMATCH'`.
4. **Re-validation complète** (cohérence avec la validation admin) :
   `PERFORM public.assert_battle_create_validations(v_battle.producer1_id, v_actor,
   v_battle.product1_id, p_product2_id, true, 400)` → rejoue producteurs actifs, écart Elo, les
   deux beats requis, éligibilité des deux beats. Si ça passe ici, l'admin validera forcément.
5. `UPDATE battles SET product2_id = p_product2_id, status = 'awaiting_admin', accepted_at = now(),
   rejected_at = NULL, rejection_reason = NULL, updated_at = now() WHERE id = p_battle_id;`
   → le trigger `trg_sync_battle_product_locks_write`
   (`supabase/migrations/20260530143000_battle_product_occupied_locks.sql:162`, déclenché
   `AFTER INSERT OR UPDATE OF product1_id, product2_id, status`) crée le lock du beat et lève
   `BATTLE_PRODUCT_ALREADY_OCCUPIED` si le beat est déjà engagé ailleurs. **Anti-occupation gratuit.**

Logique sur **refuse** (`p_accept = false`) : strictement inchangée (raison obligatoire,
`check_daily_battle_refusals`, incrément `battle_refusal_count`, `recalculate_engagement`).
`p_product2_id` est ignoré en cas de refus.

Permissions reprises à l'identique :
`REVOKE EXECUTE … FROM PUBLIC/anon/authenticated;` (l'appel passe par PostgREST avec le rôle qui a
le GRANT effectif comme l'actuel).

> Note edge-case : si `product1` est devenu inéligible entre la création et l'acceptation (beat
> dépublié par le producteur 1, producteur 1 devenu inactif), l'étape 4 fera échouer l'accept avec
> `BATTLE_PRODUCT1_INVALID` / `BATTLE_PRODUCER1_NOT_ACTIVE`. C'est le comportement correct (ne pas
> activer une battle invalide) ; il faut juste mapper ces erreurs côté front (§6).

### 4.2 `rpc_create_battle` — product1 obligatoire + cohérence genre product1

Définition actuelle : `supabase/migrations/20260530171000_battle_genre_filter.sql:76`
(signature **inchangée**, donc simple `CREATE OR REPLACE`).

Ajouts dans le corps, avant l'INSERT :
1. `IF p_product1_id IS NULL THEN RAISE EXCEPTION 'BATTLE_PRODUCT1_REQUIRED'; END IF;`
2. Cohérence genre : si `p_genre_id IS NOT NULL` et `genre_id` du beat product1 ≠ `p_genre_id` →
   `RAISE 'BATTLE_PRODUCT1_GENRE_MISMATCH'`.

L'appel existant à `assert_battle_create_validations(..., p_require_products = false)` est conservé :
product2 **reste optionnel** à la création (l'adversaire peut ne pas avoir de beat).

### 4.3 Helper de genre (DRY, optionnel)

Pour éviter de dupliquer la requête de comparaison de genre entre §4.1 et §4.2, on peut introduire
un petit helper :
```sql
is_battle_product_genre_match(p_product_id uuid, p_genre_id uuid) RETURNS boolean
-- TRUE si p_genre_id IS NULL, sinon products.genre_id = p_genre_id
```
Sinon, contrôle inline dans chaque RPC (les deux ont déjà accès au genre). **Décision :** helper
dédié pour la réutilisation et la lisibilité.

### 4.4 `assert_battle_create_validations` — inchangée

On **ne touche pas** à sa signature (évite de casser ses autres appelants : `rpc_create_battle`,
la validation admin de `20260530163000`). La cohérence de genre est gérée aux points d'écriture
(§4.1, §4.2). La validation admin continue d'exiger les 2 beats + leur éligibilité comme avant.
*(Défense en profondeur optionnelle : ajouter le helper genre dans la validation admin — non
requis car le genre est déjà garanti en amont à la création et à l'acceptation.)*

## 5. Changements front-end — `src/pages/ProducerBattles.tsx`

### 5.1 Formulaire de création
`createBattle` (`src/pages/ProducerBattles.tsx:856`) : product1 devient **obligatoire**.
- Validation : si `!form.product1Id` → `setError(t('producerBattles.product1Required'))` et stop.
- Bouton de création désactivé tant que product1 n'est pas choisi.
- Le sélecteur de product1 (alimenté par `myProducts`, chargé `:730`) devrait idéalement ne lister
  que des beats éligibles du genre choisi (cohérence UX avec la règle serveur). À cadrer dans le
  plan (filtrage `product_type='beat'`, `is_published`, `status='active'`, `genre_id = form.genreId`).

### 5.2 Carte d'invitation reçue (statut `pending_acceptance`, je suis producteur 2)
Rendu actuel ~`src/pages/ProducerBattles.tsx:1376` (boutons Accepter / Refuser + raison).
Ajouts :
- Afficher **« Battle demandée en : `<nom du genre>` »** (résoudre `battle.genre_id` → nom via la
  liste `genres` déjà chargée).
- **Sélecteur de beat** : mes beats (`producer_id = profile.id`) filtrés par `battle.genre_id`,
  éligibles (`is_published`, non supprimés, beats actifs), beats **occupés grisés** via
  `get_occupied_product_ids` (`supabase/migrations/20260624070000_get_occupied_product_ids_rpc.sql`).
  Charger ces beats à l'affichage des invitations (nouvel état + requête, sur le modèle de
  `loadProducer2Products` `:799`).
- Bouton **« Accepter » désactivé** tant qu'aucun beat n'est sélectionné.
- Si **aucun beat éligible dans ce style** → message « Tu n'as pas de beat en `<genre>` — uploade un
  beat dans ce style, ou refuse la demande. » + **lien vers la page d'upload** (`UploadBeat.tsx`) +
  bouton Refuser disponible. *(Option : pré-sélectionner le genre via query param sur le lien upload.)*
- `respondToBattle(battleId, true)` (`:929`) envoie désormais `p_product2_id` au RPC.

## 6. Gestion d'erreurs + i18n (4 langues : fr, en, es, …)

Mapper en messages clairs (helpers `toBattleInsertErrorMessage` pour la création, et l'équivalent
pour la réponse) :

| Code | Contexte | Message (idée) |
|------|----------|----------------|
| `BATTLE_PRODUCT2_REQUIRED` | accept | « Choisis un beat pour accepter cette battle. » |
| `BATTLE_PRODUCT2_INVALID` | accept | « Ce beat n'est pas éligible (doit être un beat publié et actif). » |
| `BATTLE_PRODUCT2_GENRE_MISMATCH` | accept | « Ce beat n'est pas dans le style demandé (`<genre>`). » |
| `BATTLE_PRODUCT_ALREADY_OCCUPIED` | accept | « Ce beat est déjà engagé dans une autre battle. » |
| `BATTLE_PRODUCER1_NOT_ACTIVE` / `BATTLE_PRODUCT1_INVALID` | accept (edge) | « Le créateur ou son beat n'est plus disponible. » |
| `BATTLE_PRODUCT1_REQUIRED` | création | « Sélectionne ton beat pour lancer la demande. » |
| `BATTLE_PRODUCT1_GENRE_MISMATCH` | création | « Ton beat doit être dans le style choisi. » |

## 7. Types

Régénérer `src/lib/supabase/database.types.ts` après la migration :
- `respond_to_battle.Args` devient
  `{ p_battle_id: string; p_accept: boolean; p_reason?: string; p_product2_id?: string }`.
- `rpc_create_battle.Args` inchangé (signature inchangée).

## 8. Tests

**DB (SQL) :**
- accept sans `p_product2_id` → `BATTLE_PRODUCT2_REQUIRED`.
- accept avec beat valide du bon genre → statut `awaiting_admin`, `product2_id` rempli, lock créé.
- accept avec beat d'un autre genre → `BATTLE_PRODUCT2_GENRE_MISMATCH`.
- accept avec beat déjà engagé ailleurs → `BATTLE_PRODUCT_ALREADY_OCCUPIED`.
- accept avec beat non publié / non-beat → `BATTLE_PRODUCT2_INVALID`.
- refuse → comportement inchangé (raison requise, quota refus).
- création sans product1 → `BATTLE_PRODUCT1_REQUIRED` ; product1 d'un autre genre →
  `BATTLE_PRODUCT1_GENRE_MISMATCH`.
- cycle complet : création (product1) → accept-avec-beat (product2) → validation admin OK.

**Front :**
- bouton « Accepter » désactivé sans sélection de beat.
- producteur 2 sans beat dans le style → message + lien upload visibles ; refus possible.
- genre de la battle affiché correctement sur la carte.
- création : bouton désactivé sans product1.

## 9. Déploiement & ordre des migrations

- Déploiement **file-based** (`supabase db push`) pour garantir l'ordre, la migration dépendant de
  `20260624073000`. Si l'on passe par MCP `apply_migration`, **réaligner `schema_migrations.version`**
  ensuite (contrainte connue : `apply_migration` génère sa propre version distante et casse les
  `db push` suivants).
- Appliquer **après** les migrations `20260624…` déjà écrites mais pas encore déployées
  (`20260624073000` battle active-check, locks/expiry d'invitation, `get_occupied_product_ids`).
- ⚠️ Le worker audio Render pointe sur la **prod** — pas d'impact direct ici, mais rappel que toute
  migration appliquée touche la prod.
- **Battles déjà bloquées** en `awaiting_admin` sans `product2` (créées avant ce correctif) ne sont
  pas migrées automatiquement : à annuler côté admin. Lister via une requête de contrôle au déploiement.

## 10. Fichiers concernés (récap)

- `supabase/migrations/20260624XXXXXX_battle_accept_with_beat.sql` *(nouveau)* — `respond_to_battle`
  (drop + recreate 4-args), `rpc_create_battle` (replace), helper genre.
- `src/pages/ProducerBattles.tsx` — création (product1 requis), carte d'invitation (genre + sélecteur
  beat + lien upload), `respondToBattle` (envoi `p_product2_id`).
- `src/lib/supabase/database.types.ts` — régénéré.
- Fichiers i18n (4 langues) — nouveaux libellés d'erreur et de l'UI d'acceptation.
