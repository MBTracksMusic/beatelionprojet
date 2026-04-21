# Ajout catégories formulaire upload beat — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter les champs Genre, Ambiance et Tags au formulaire d'upload de beat, et afficher un nudge dans le ProducerDashboard pour les beats existants sans genre.

**Architecture:** L'infrastructure DB (tables `genres`/`moods`, colonnes `genre_id`/`mood_id`/`tags` sur `products`) est déjà en place. On ajoute uniquement l'UI producteur dans `UploadBeat.tsx` et un bandeau nudge dans `ProducerDashboard.tsx`. Aucune migration SQL nécessaire.

**Tech Stack:** React 18, TypeScript, Supabase JS client, Tailwind CSS, composants `Select` et `Input` locaux (`src/components/ui/`).

---

## Fichiers modifiés

| Fichier | Rôle des changements |
|---|---|
| `src/lib/i18n/translations/fr.ts` | 10 nouvelles clés uploadBeat + producerDashboard |
| `src/lib/i18n/translations/en.ts` | Idem EN |
| `src/lib/i18n/translations/de.ts` | Idem DE |
| `src/pages/UploadBeat.tsx` | Type, imports, état, fetch, UI, validation, payload, reset |
| `src/pages/ProducerDashboard.tsx` | Requête count + bandeau nudge |

---

## Task 1 — Clés i18n (fr / en / de)

**Files:**
- Modify: `src/lib/i18n/translations/fr.ts`
- Modify: `src/lib/i18n/translations/en.ts`
- Modify: `src/lib/i18n/translations/de.ts`

- [ ] **Step 1 : Ajouter les clés dans fr.ts — section `uploadBeat`**

Repère la ligne contenant `watermarkProcessing` dans la section `uploadBeat`. Ajoute juste après :

```ts
    genreLabel: 'Genre',
    moodLabel: 'Ambiance',
    tagsLabel: 'Tags',
    genrePlaceholder: '— Sélectionner —',
    moodPlaceholder: '— Sélectionner —',
    tagsPlaceholder: 'Ex: drill, sombre, 808...',
    genreRequired: 'Veuillez choisir un genre.',
    genreRecommended: 'Recommandé',
```

- [ ] **Step 2 : Ajouter les clés dans fr.ts — section `producerDashboard`**

Repère la ligne contenant `createVersion` dans la section `producerDashboard`. Ajoute juste après :

```ts
    uncategorizedNudge: '{count} de tes beats n\'ont pas de genre — catégorise-les pour booster leur visibilité dans les filtres.',
    uncategorizedDismiss: 'Ignorer',
```

- [ ] **Step 3 : Ajouter les clés dans en.ts — section `uploadBeat`**

Repère la ligne contenant `watermarkProcessing` (ligne ~830). Ajoute juste après :

```ts
    genreLabel: 'Genre',
    moodLabel: 'Mood',
    tagsLabel: 'Tags',
    genrePlaceholder: '— Select —',
    moodPlaceholder: '— Select —',
    tagsPlaceholder: 'E.g.: drill, dark, 808...',
    genreRequired: 'Please select a genre.',
    genreRecommended: 'Recommended',
```

- [ ] **Step 4 : Ajouter les clés dans en.ts — section `producerDashboard`**

Repère la ligne contenant `createVersion` (ligne ~715). Ajoute juste après :

```ts
    uncategorizedNudge: '{count} of your beats have no genre — categorize them to boost visibility in filters.',
    uncategorizedDismiss: 'Dismiss',
```

- [ ] **Step 5 : Ajouter les clés dans de.ts — section `uploadBeat`**

Repère la ligne contenant `watermarkProcessing` (ligne ~828). Ajoute juste après :

```ts
    genreLabel: 'Genre',
    moodLabel: 'Stimmung',
    tagsLabel: 'Tags',
    genrePlaceholder: '— Auswählen —',
    moodPlaceholder: '— Auswählen —',
    tagsPlaceholder: 'Bsp.: drill, dunkel, 808...',
    genreRequired: 'Bitte wähle ein Genre aus.',
    genreRecommended: 'Empfohlen',
```

- [ ] **Step 6 : Ajouter les clés dans de.ts — section `producerDashboard`**

Repère la ligne contenant `createVersion` (ligne ~713). Ajoute juste après :

```ts
    uncategorizedNudge: '{count} deiner Beats haben kein Genre — kategorisiere sie für bessere Sichtbarkeit in den Filtern.',
    uncategorizedDismiss: 'Ausblenden',
```

- [ ] **Step 7 : Commit**

```bash
git add src/lib/i18n/translations/fr.ts src/lib/i18n/translations/en.ts src/lib/i18n/translations/de.ts
git commit -m "feat: add i18n keys for genre/mood/tags upload form and dashboard nudge"
```

---

## Task 2 — UploadBeat.tsx : types, imports, état, fetch, init édition

**Files:**
- Modify: `src/pages/UploadBeat.tsx:1,63` (imports + interfaces)
- Modify: `src/pages/UploadBeat.tsx:291` (useTranslation)
- Modify: `src/pages/UploadBeat.tsx:315-320` (state vars)
- Modify: `src/pages/UploadBeat.tsx:380-390` (versionSource init)
- Modify: `src/pages/UploadBeat.tsx:425-460` (editingProduct select + init)

- [ ] **Step 1 : Étendre l'interface `EditProductRow` (ligne 52)**

L'interface actuelle (lignes 52-62) ne contient pas `genre_id`, `mood_id`, `tags`. Remplace-la par :

```ts
interface EditProductRow {
  id: string;
  title: string;
  description: string | null;
  price: number;
  bpm: number | null;
  key_signature: string | null;
  cover_image_url: string | null;
  is_published: boolean;
  file_format: string | null;
  genre_id: string | null;
  mood_id: string | null;
  tags: string[] | null;
}
```

- [ ] **Step 2 : Ajouter les imports manquants**

La ligne 23 contient :
```ts
import { Input } from '../components/ui/Input';
```

Remplace-la par :
```ts
import { Input } from '../components/ui/Input';
import { Select } from '../components/ui/Select';
```

Ajoute ensuite ces deux imports (après les imports existants, avant la première ligne non-import) :
```ts
import { getLocalizedName } from '../lib/i18n/localized';
import type { Genre, Mood } from '../lib/supabase/types';
```

- [ ] **Step 3 : Ajouter `language` à la destructuration de `useTranslation` (ligne ~291)**

Remplace :
```ts
const { t } = useTranslation();
```
par :
```ts
const { t, language } = useTranslation();
```

- [ ] **Step 4 : Ajouter les variables d'état (après ligne ~317)**

Après la ligne `const [keySignature, setKeySignature] = useState('');`, ajoute :

```ts
const [genreId, setGenreId] = useState<string>('');
const [moodId, setMoodId] = useState<string>('');
const [tags, setTags] = useState<string[]>([]);
const [tagInput, setTagInput] = useState('');
const [genres, setGenres] = useState<Genre[]>([]);
const [moods, setMoods] = useState<Mood[]>([]);
const tagInputRef = useRef<HTMLInputElement>(null);
```

- [ ] **Step 5 : Ajouter le fetch genres/moods au montage**

Après le dernier `useEffect` existant (cherche la zone des useEffects, vers la ligne 340), ajoute un nouvel effet :

```ts
useEffect(() => {
  async function fetchCategoryData() {
    const [genresRes, moodsRes] = await Promise.all([
      supabase.from('genres').select('*').eq('is_active', true).order('sort_order'),
      supabase.from('moods').select('*').eq('is_active', true).order('sort_order'),
    ]);
    if (genresRes.data) setGenres(genresRes.data as Genre[]);
    if (moodsRes.data) setMoods(moodsRes.data as Mood[]);
  }
  fetchCategoryData();
}, []);
```

- [ ] **Step 6 : Initialiser genre/mood/tags depuis `versionSource` (ligne ~382)**

Juste après les lignes `setDescription(sourceRow.description ?? '');` et `setBpm(...)` dans le bloc versionSource, ajoute :

```ts
          setGenreId(sourceRow.genre_id ?? '');
          setMoodId(sourceRow.mood_id ?? '');
          setTags(sourceRow.tags ?? []);
```

- [ ] **Step 7 : Étendre la requête editingProduct pour inclure genre/mood/tags (ligne ~429)**

Remplace :
```ts
.select('id, title, description, price, bpm, key_signature, cover_image_url, is_published, file_format')
```
par :
```ts
.select('id, title, description, price, bpm, key_signature, cover_image_url, is_published, file_format, genre_id, mood_id, tags')
```

- [ ] **Step 8 : Initialiser genre/mood/tags depuis `editingProduct` (ligne ~455)**

Juste après la ligne `setKeySignature(sourceRow.key_signature ?? '');` dans le bloc editingProduct, ajoute :

```ts
          setGenreId(sourceRow.genre_id ?? '');
          setMoodId(sourceRow.mood_id ?? '');
          setTags(sourceRow.tags ?? []);
```

- [ ] **Step 9 : Commit**

```bash
git add src/pages/UploadBeat.tsx
git commit -m "feat: add genre/mood/tags state, fetch and edit-mode init to UploadBeat"
```

---

## Task 3 — UploadBeat.tsx : UI, validation, payload, reset

**Files:**
- Modify: `src/pages/UploadBeat.tsx:731-748` (validation)
- Modify: `src/pages/UploadBeat.tsx:821-835` (basePayload)
- Modify: `src/pages/UploadBeat.tsx:859-875` (edit update payload)
- Modify: `src/pages/UploadBeat.tsx:920-925` (state reset)
- Modify: `src/pages/UploadBeat.tsx:1070-1072` (UI insertion)

- [ ] **Step 1 : Ajouter le handler chip input**

Avant le `return` JSX du composant (cherche `return (` après tous les hooks), ajoute :

```ts
  const handleTagKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      const value = tagInput.trim().toLowerCase().slice(0, 25);
      if (value && !tags.includes(value) && tags.length < 8) {
        setTags([...tags, value]);
      }
      setTagInput('');
    } else if (e.key === 'Backspace' && tagInput === '' && tags.length > 0) {
      setTags(tags.slice(0, -1));
    }
  };
```

- [ ] **Step 2 : Ajouter la validation genre (ligne ~742)**

Après le bloc de validation du prix (après la ligne `return;` qui suit le check `priceValue < 0`), ajoute :

```ts
    if (!genreId && !editingProduct) {
      setErrors((prev) => ({ ...prev, form: t('uploadBeat.genreRequired') }));
      return;
    }
```

- [ ] **Step 3 : Ajouter genre/mood/tags dans `basePayload` (ligne ~821)**

La ligne `is_published: editingProduct?.is_published ?? true,` est suivie de `duration_seconds` et `file_format`. Après `file_format`, dans `basePayload`, ajoute :

```ts
        genre_id: genreId || null,
        mood_id: moodId || null,
        tags: tags.length > 0 ? tags : [],
```

- [ ] **Step 4 : Ajouter genre/mood/tags dans le payload d'édition (ligne ~861)**

Dans le bloc `else if (editingProduct)`, le payload de mise à jour contient `title`, `description`, `bpm`, `key_signature`. Après `key_signature: keySignature || null,`, ajoute :

```ts
          genre_id: genreId || null,
          mood_id: moodId || null,
          tags: tags.length > 0 ? tags : [],
```

- [ ] **Step 5 : Ajouter les resets d'état (ligne ~922)**

Après les lignes `setDescription('');` et `setBpm('');` dans la zone de reset post-upload, ajoute :

```ts
      setGenreId('');
      setMoodId('');
      setTags([]);
      setTagInput('');
```

- [ ] **Step 6 : Insérer les champs UI entre Description et BPM**

Repère le bloc fermant `</div>` de la Description (ligne ~1070) suivi du `<div className="grid grid-cols-1 md:grid-cols-2 gap-4">` du BPM (ligne ~1072). Entre ces deux blocs, insère :

```tsx
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <Select
                label={t('uploadBeat.genreLabel')}
                name="genre"
                value={genreId}
                onChange={(e) => setGenreId(e.target.value)}
                disabled={isUploading || isMetadataLocked}
                options={[
                  { value: '', label: t('uploadBeat.genrePlaceholder') },
                  ...genres.map((g) => ({ value: g.id, label: getLocalizedName(g, language) })),
                ]}
              />
              {!genreId && editingProduct && (
                <p className="mt-1 text-xs text-amber-400">{t('uploadBeat.genreRecommended')}</p>
              )}
            </div>
            <Select
              label={t('uploadBeat.moodLabel')}
              name="mood"
              value={moodId}
              onChange={(e) => setMoodId(e.target.value)}
              disabled={isUploading || isMetadataLocked}
              options={[
                { value: '', label: t('uploadBeat.moodPlaceholder') },
                ...moods.map((m) => ({ value: m.id, label: getLocalizedName(m, language) })),
              ]}
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-1.5">
              {t('uploadBeat.tagsLabel')}
            </label>
            <div
              className="flex flex-wrap gap-1.5 w-full bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 focus-within:ring-2 focus-within:ring-rose-500/50 focus-within:border-rose-500 min-h-[44px] cursor-text"
              onClick={() => tagInputRef.current?.focus()}
            >
              {tags.map((tag) => (
                <span
                  key={tag}
                  className="flex items-center gap-1 bg-zinc-700 text-zinc-200 text-xs px-2 py-1 rounded-full"
                >
                  {tag}
                  <button
                    type="button"
                    onClick={(e) => { e.stopPropagation(); setTags(tags.filter((existing) => existing !== tag)); }}
                    className="text-zinc-400 hover:text-white leading-none"
                    disabled={isUploading || isMetadataLocked}
                  >
                    ×
                  </button>
                </span>
              ))}
              {tags.length < 8 && (
                <input
                  ref={tagInputRef}
                  type="text"
                  className="flex-1 min-w-[120px] bg-transparent text-sm text-white placeholder-zinc-500 outline-none"
                  placeholder={tags.length === 0 ? t('uploadBeat.tagsPlaceholder') : ''}
                  value={tagInput}
                  onChange={(e) => setTagInput(e.target.value)}
                  onKeyDown={handleTagKeyDown}
                  disabled={isUploading || isMetadataLocked}
                />
              )}
            </div>
          </div>
```

- [ ] **Step 7 : Vérification manuelle**

Lance le dev server :
```bash
npm run dev
```

Ouvre `/upload-beat` et vérifie :
1. Les dropdowns Genre et Ambiance sont peuplés avec les 10 genres / 8 moods
2. Le chip input tags fonctionne : frappe un mot + Entrée → chip créé ; × supprime ; max 8 respecté
3. Soumettre sans genre → message d'erreur rouge
4. En mode édition (ajoute `?edit=<id>` dans l'URL) → genre optionnel, label "Recommandé" si vide

- [ ] **Step 8 : Commit**

```bash
git add src/pages/UploadBeat.tsx
git commit -m "feat: add genre/mood/tags UI, validation and payload to UploadBeat form"
```

---

## Task 4 — ProducerDashboard : nudge beats sans genre

**Files:**
- Modify: `src/pages/ProducerDashboard.tsx:162-182` (état)
- Modify: `src/pages/ProducerDashboard.tsx:210-250` (Promise.all)
- Modify: `src/pages/ProducerDashboard.tsx:942-960` (UI nudge)

- [ ] **Step 1 : Ajouter les états nudge (ligne ~182)**

Après la ligne `const [stripeConnectError, setStripeConnectError] = useState<string | null>(null);`, ajoute :

```ts
  const [uncategorizedCount, setUncategorizedCount] = useState(0);
  const [nudgeDismissed, setNudgeDismissed] = useState(false);
```

- [ ] **Step 2 : Ajouter la 6e requête dans le Promise.all (ligne ~216)**

Le `Promise.all` destructure 5 résultats. Étends-le à 6 :

Remplace la destructuration :
```ts
        const [
          { count: totalProducts, error: productCountError },
          { data: productsData, error: productsError },
          { data: purchaseRows, error: salesError },
          { data: activeBattleRows, error: activeBattleError },
          { data: terminatedBattleRows, error: terminatedBattleError },
        ] = await Promise.all([
```
par :
```ts
        const [
          { count: totalProducts, error: productCountError },
          { data: productsData, error: productsError },
          { data: purchaseRows, error: salesError },
          { data: activeBattleRows, error: activeBattleError },
          { data: terminatedBattleRows, error: terminatedBattleError },
          { count: uncategorized },
        ] = await Promise.all([
```

Puis ajoute la 6e requête à la fin du tableau passé à `Promise.all` (juste avant le `])`):

```ts
          supabase
            .from('products')
            .select('*', { count: 'exact', head: true })
            .eq('producer_id', profile.id)
            .eq('is_published', true)
            .is('genre_id', null)
            .is('deleted_at', null),
```

- [ ] **Step 3 : Stocker le count dans l'état**

Dans le bloc `if (!isCancelled)` qui suit le Promise.all (là où `setProductCount` est appelé), ajoute :

```ts
          setUncategorizedCount(uncategorized ?? 0);
```

- [ ] **Step 4 : Afficher le bandeau nudge (ligne ~955)**

Dans la section `<section>` des produits, avant le bloc :
```tsx
          {!isLoading && !error && products.length > 0 && (
```
ajoute :

```tsx
          {!isLoading && !error && uncategorizedCount > 0 && !nudgeDismissed && (
            <div className="flex items-start justify-between gap-3 mb-4 bg-amber-500/10 border border-amber-500/30 rounded-lg px-4 py-3 text-sm">
              <p className="text-amber-300">
                {t('producerDashboard.uncategorizedNudge', { count: uncategorizedCount })}
              </p>
              <button
                onClick={() => setNudgeDismissed(true)}
                className="text-zinc-400 hover:text-white shrink-0 mt-0.5"
              >
                {t('producerDashboard.uncategorizedDismiss')}
              </button>
            </div>
          )}
```

- [ ] **Step 5 : Vérification manuelle**

Sur le ProducerDashboard d'un compte ayant des beats publiés sans genre :
1. Le bandeau amber apparaît avec le bon count
2. Cliquer "Ignorer" le fait disparaître
3. Sur un compte où tous les beats ont un genre : bandeau absent

- [ ] **Step 6 : Commit**

```bash
git add src/pages/ProducerDashboard.tsx
git commit -m "feat: add uncategorized beats nudge to ProducerDashboard"
```
