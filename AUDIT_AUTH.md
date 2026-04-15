# Audit — Système d'Authentification Beatelion
> Généré le 2026-04-15 — Mode lecture seule, aucune modification effectuée

---

## 1. Architecture actuelle

```
┌─────────────────────────────────────────────────────────────────┐
│                         FRONTEND (React)                        │
│                                                                 │
│  App.tsx                                                        │
│   └─ useEffect → initializeAuth() (une seule fois)             │
│       ├─ getSession()                                           │
│       └─ onAuthStateChange listener                             │
│                                                                 │
│  Pages Auth           Zustand Store          Hooks              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ Login.tsx    │    │ store.ts     │    │ useAuth()    │      │
│  │ Register.tsx │───▶│  user        │───▶│ useIsAdmin() │      │
│  │ ForgotPwd    │    │  session     │    │ useCanSell() │      │
│  │ ResetPwd     │    │  profile     │    │ usePerms()   │      │
│  │ EmailConf    │    │  isLoading   │    └──────────────┘      │
│  └──────────────┘    │  isInit'd    │                          │
│                      └──────────────┘                          │
│                                                                 │
│  service.ts (wrapper)                                          │
│   ├─ signUp()   → supabase.functions.invoke('auth-signup')     │
│   ├─ signIn()   → supabase.functions.invoke('auth-login')      │
│   ├─ signOut()  → supabase.auth.signOut()           [DIRECT]   │
│   ├─ resetPwd() → supabase.functions.invoke('auth-forgot-pwd') │
│   └─ updatePwd()→ supabase.auth.updateUser()        [DIRECT]   │
│                                                                 │
│  client.ts                                                     │
│   └─ createClient({                                            │
│        storage key: 'sb-levelupmusic-auth',                    │
│        persistSession: true,                                   │
│        autoRefreshToken: true,                                 │
│        detectSessionInUrl: true  ← IMPORTANT                  │
│      })                                                        │
└──────────────────────────┬──────────────────────────────────────┘
                           │ supabase.functions.invoke()
                           │ + Authorization: Bearer <token>
┌──────────────────────────▼──────────────────────────────────────┐
│                  SUPABASE EDGE FUNCTIONS                        │
│                                                                 │
│  auth-signup           auth-login          auth-forgot-pwd      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ IP rate limit│    │ IP rate limit│    │ IP rate limit│      │
│  │ hCaptcha     │    │ hCaptcha     │    │ hCaptcha     │      │
│  │ signUp()     │    │ signInWithPwd│    │ resetPwdEmail│      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│                                                                 │
│  auth-send-email (Webhook)                                     │
│   └─ Triggered by Supabase auth events                         │
│   └─ Envoie via Resend (emails FR custom)                      │
│   └─ Déduplication + rate limit 24h par email                  │
└─────────────────────────────────────────────────────────────────┘
```

**Stack clé :**
- `@supabase/supabase-js` v2
- Zustand pour le state auth
- hCaptcha sur signup / login / forgot-password
- Resend pour l'envoi d'emails (via webhook Supabase)
- Clé de stockage custom : `sb-levelupmusic-auth` (vestige d'un ancien nom de projet)

---

## 2. Flux d'auth détaillés

### Signup
```
Register.tsx → service.signUp()
  → Edge Function auth-signup
      → IP hash + rate limit
      → hCaptcha verify
      → supabase.auth.signUp({ redirectTo: "https://www.beatelion.com/email-confirmation" })
      → return { user, session }
  → hydrateBrowserSession() [setSession côté client]
  → si !user.confirmed_at → /email-confirmation?email=xxx
  → si producer → /tarifs

  [Async] Supabase auth webhook → auth-send-email
    → Email "Confirme ton compte" via Resend
    → URL dans email : https://www.beatelion.com?token_hash=xxx&type=signup
                                              ↑
                           NOTE: pas /email-confirmation, c'est la homepage

  Clic email → /email-confirmation?token_hash=xxx&type=signup
    → exchangeCodeForSession(code) OU verifyOtp({type:'signup', token_hash})
    → Succès → redirect / après 2 secondes
```

### Login
```
Login.tsx → service.signIn()
  → Edge Function auth-login
      → IP hash + rate limit
      → hCaptcha verify
      → supabase.auth.signInWithPassword()
      → return { user, session }
  → hydrateBrowserSession()
  → si email non confirmé → /email-confirmation
  → fetch role depuis user_profiles
  → admin → /admin | autres → /dashboard (ou 'from' si redirect protégé)

  [Async] onAuthStateChange(SIGNED_IN) dans store.ts
    → fetchProfile() depuis my_user_profile view
    → Updates permissions dans store
```

### Reset Password
```
ForgotPassword.tsx → service.resetPassword()
  → Edge Function auth-forgot-password
      → IP hash + rate limit
      → hCaptcha verify
      → supabase.auth.resetPasswordForEmail({ redirectTo: ".../reset-password" })

  [Async] Email via Resend : lien #access_token=...&type=recovery

  ResetPassword.tsx (sur /reset-password)
    → Lit hash params : access_token + refresh_token OU code OU token_hash
    → Méthode 1 : exchangeCodeForSession(code)
    → Méthode 2 : verifyOtp({ type: 'recovery', token_hash })
    → Méthode 3 : setSession({ access_token, refresh_token })
    → Affiche form nouveau mot de passe
    → submit → supabase.auth.updateUser({ password })
    → signOut global → redirect /login
```

### Email Confirmation
```
EmailConfirmation.tsx gère DEUX états :
  1. État d'attente (juste après signup) → affiche email + bouton resend
  2. État de traitement (après clic lien) → valide token → succès
     → Méthode 1 : exchangeCodeForSession(code)
     → Méthode 2 : verifyOtp({ type: 'signup'|'email_change'|'invite'|'magiclink', token_hash })
     → Méthode 3 : setSession(access_token, refresh_token)
     → Auto-redirect / après 2 secondes
```

---

## 3. Points critiques / fragiles

### Fragilité 1 — URL dans l'email de confirmation (non-standard)
L'Edge Function `auth-send-email` construit les URLs ainsi :
```
https://www.beatelion.com?token_hash=xxx&type=signup
```
C'est la **homepage**, pas `/email-confirmation`. La page `EmailConfirmation.tsx` doit donc être montée à `/email-confirmation` mais aussi potentiellement à `/`. **À vérifier** : est-ce que `App.tsx` gère les auth params sur `/` ?

### Fragilité 2 — Clé de stockage `sb-levelupmusic-auth`
Le `client.ts` utilise une clé custom qui correspond à un **ancien nom de projet** (levelupmusic). Il y a même une migration de clé pour l'ancienne clé Supabase par défaut. Si un utilisateur a une session stockée sous l'ancienne clé, il y a déjà un mécanisme de migration — mais c'est un point de fragilité à surveiller lors de tout changement de client.

### Fragilité 3 — Triple méthode de récupération de token
`ResetPassword.tsx` et `EmailConfirmation.tsx` implémentent **3 méthodes différentes** de traitement des tokens (PKCE code, OTP token_hash, direct tokens). C'est défensif mais crée de la complexité. Si Supabase change son format d'URL, certaines méthodes pourraient entrer en conflit.

### Fragilité 4 — Race condition potentielle dans initializeAuth
```
getSession() → onAuthStateChange()
     ↓                 ↓
fetchProfile()    fetchProfile()  ← double appel possible
```
Il y a un verrou `profileFetchInFlight` dans `store.ts` pour éviter ça — c'est bien géré, mais c'est un point à ne pas perturber.

### Fragilité 5 — hCaptcha obligatoire sur TOUS les flows
Signup, login, et forgot-password passent tous par les Edge Functions qui **requièrent** `captchaToken`. Il n'existe **aucun bypass** pour OAuth. Si Google Auth ne passe pas par ces Edge Functions (ce qui est le cas), il faudra un chemin séparé pour la création de profil.

### Fragilité 6 — Création de profil dans auth-signup seulement
Le profil utilisateur (`user_profiles`) est créé dans le flow de l'Edge Function `auth-signup`. Un utilisateur Google Auth arriverait sans profil → la vue `my_user_profile` retournerait null → `fetchProfile()` échouerait silencieusement ou signerait l'utilisateur hors session (logique `is_deleted`).

---

## 4. Risques d'intégration Google Auth

### Risque 1 — Création de profil manquante (CRITIQUE)
`signInWithOAuth` de Supabase contourne totalement `auth-signup`. Il faut **une trigger SQL** sur `auth.users` ou un **callback dédié** pour créer le `user_profiles` à la volée pour les OAuth users.

### Risque 2 — Callback route inexistante
`signInWithOAuth` nécessite un `redirectTo` vers une route callback (ex: `/auth/callback`). Cette route **n'existe pas** dans `App.tsx` actuellement. Il faut l'ajouter dans le routing ET dans les `LAUNCH_BYPASS_PATHS`.

### Risque 3 — `redirectTo` et les URLs autorisées Supabase
Le `redirectTo` passé à `signInWithOAuth` doit être dans la **liste des URLs autorisées** dans le dashboard Supabase (Redirect URLs). Les URLs actuelles configurées (`/email-confirmation`, `/reset-password`) ne couvrent pas une route `/auth/callback`.

### Risque 4 — Email confirmation = non applicable pour Google
Les utilisateurs Google ont leur email déjà vérifié par Google. La logique `email_not_confirmed` dans `Login.tsx` et les checks `is_confirmed` dans les permissions doivent traiter ces utilisateurs comme confirmés — mais ça dépend de comment Supabase peuple `email_confirmed_at` pour les OAuth users (il le fait automatiquement, mais à vérifier avec la vue `my_user_profile`).

### Risque 5 — hCaptcha inapplicable
`auth-login` Edge Function requiert `captchaToken`. Le flow Google Auth ne passe **jamais** par cette Edge Function — c'est `supabase.auth.signInWithOAuth()` direct. La session sera créée directement par Supabase. `onAuthStateChange` prendra le relai, ce qui est OK — mais le profil ne sera pas créé (voir Risque 1).

### Risque 6 — `hydrateBrowserSession()` non appelé
Après OAuth, la session est injectée automatiquement via `detectSessionInUrl: true` + `onAuthStateChange`. Il faut s'assurer que le callback route déclenche bien la mise à jour du store avant de rediriger vers `/dashboard`.

### Risque 7 — Username obligatoire dans user_profiles
Le schéma actuel semble requérir un `username`. Un utilisateur Google n'en aura pas à la création. Il faut soit le rendre optionnel, soit forcer un onboarding post-OAuth pour collecter le username.

---

## 5. Niveau de complexité

| Aspect | Niveau | Raison |
|--------|--------|--------|
| Ajout du bouton Google dans Login/Register | Facile | Un appel `signInWithOAuth` |
| Création de la route callback | Facile | Nouveau composant simple |
| Trigger SQL pour créer le profil | Moyen | Nécessite migration DB + test RLS |
| Gestion username manquant | Moyen | Onboarding flow à créer |
| Configuration Supabase Dashboard | Facile | Redirect URLs + Google provider |
| Compatibilité avec email confirmation | Moyen | Vérifier la vue `my_user_profile` |
| Non-régression sur les flows existants | Risqué | Triple token handling + hCaptcha |

**Verdict global : MOYEN** — le système actuel est solide et bien structuré, mais l'ajout OAuth touche à plusieurs points sensibles (profil, username, callback route, permissions).

---

## 6. Checklist AVANT implémentation

### Supabase Dashboard
- [ ] Activer Google OAuth provider (Client ID + Secret)
- [ ] Ajouter `https://www.beatelion.com/auth/callback` dans les Redirect URLs autorisées
- [ ] Vérifier que `detectSessionInUrl` est bien activé (c'est le cas côté client)

### Base de données
- [ ] Vérifier si `username` est `NOT NULL` dans `user_profiles`
- [ ] Vérifier si une trigger `handle_new_user` existe déjà sur `auth.users`
- [ ] Rédiger la trigger SQL pour créer un profil à la création d'un OAuth user
- [ ] Tester la vue `my_user_profile` avec un user OAuth (`email_confirmed_at` présent ?)

### Frontend
- [ ] Créer la route `/auth/callback` dans `App.tsx`
- [ ] Ajouter `/auth/callback` dans `LAUNCH_BYPASS_PATHS`
- [ ] Décider du comportement post-callback : redirect vers `/dashboard` ou onboarding username
- [ ] Vérifier que `ProtectedRoute` tolère un profil sans username

### Flux email confirmation
- [ ] Confirmer que `is_confirmed` est bien `true` pour les OAuth users dans la vue
- [ ] S'assurer que la logique `email_not_confirmed` dans `Login.tsx` ne bloque pas les OAuth users

### Tests de non-régression
- [ ] Signup email/password → toujours fonctionnel
- [ ] Login email/password → toujours fonctionnel
- [ ] Reset password → lien email → form → succès
- [ ] Email confirmation → lien email → redirect home

---

## Fichiers clés

| Fichier | Rôle |
|---------|------|
| `src/lib/supabase/client.ts` | Client Supabase (config, storage key) |
| `src/lib/auth/service.ts` | Wrapper auth (signUp, signIn, resetPwd…) |
| `src/lib/auth/store.ts` | Zustand store + initializeAuth + onAuthStateChange |
| `src/lib/auth/hooks.ts` | useAuth, usePermissions, useIsProducer… |
| `src/lib/auth/redirects.ts` | Helpers URL (getAuthRedirectUrl) |
| `src/components/auth/ProtectedRoute.tsx` | Route guard (requireProducer, requireAdmin) |
| `src/pages/auth/Login.tsx` | Page login |
| `src/pages/auth/Register.tsx` | Page inscription |
| `src/pages/auth/ForgotPassword.tsx` | Page mot de passe oublié |
| `src/pages/auth/ResetPassword.tsx` | Page réinitialisation mot de passe |
| `src/pages/auth/EmailConfirmation.tsx` | Page confirmation email |
| `src/App.tsx` | Routing + bootstrap auth |
| `supabase/functions/auth-signup/index.ts` | Edge Function signup |
| `supabase/functions/auth-login/index.ts` | Edge Function login |
| `supabase/functions/auth-forgot-password/index.ts` | Edge Function reset password |
| `supabase/functions/auth-send-email/index.ts` | Webhook emails (Resend) |
| `supabase/functions/_shared/hcaptcha.ts` | Vérification hCaptcha |
| `supabase/functions/_shared/auth.ts` | Helpers auth serveur |
