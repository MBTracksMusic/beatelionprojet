# Registration Security Patch — Waitlist→Whitelist & Register Gate

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two registration security gaps: (1) accepting a waitlist entry now also upserts the email into `access_whitelist`; (2) `/register` blocks unauthorized emails in closed modes.

**Architecture:** Minimal 3-file patch. A new SQL function `can_email_register(p_email)` (SECURITY DEFINER, grants to `anon`) returns a boolean that Register.tsx calls before `signUp()`. AdminLaunchPage.tsx extends `updateStatus()` to sequentially upsert `access_whitelist` after a successful waitlist acceptance. No Stripe, no RLS, no is_producer_active touched.

**Tech Stack:** React 18, TypeScript, Supabase JS client v2, react-hot-toast (admin), custom useToast (register), PostgreSQL SECURITY DEFINER function.

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `supabase/migrations/20260510030000_add_can_email_register_rpc.sql` | New public RPC returning boolean; grants to anon |
| Modify | `src/pages/admin/AdminLaunchPage.tsx` (lines ~1169–1193) | `updateStatus()` — upsert whitelist after waitlist accept |
| Modify | `src/pages/auth/Register.tsx` (lines ~1, ~127) | Add supabase import; guard `signUp()` with RPC check |

---

## Schema Reference (confirmed from migration 20260406120000)

`access_whitelist` columns:
- `id` uuid PRIMARY KEY DEFAULT gen_random_uuid()
- `email` text **UNIQUE NOT NULL**
- `user_id` uuid nullable (references auth.users)
- `granted_by` uuid nullable (references auth.users)
- `granted_at` timestamptz NOT NULL DEFAULT now()
- `note` text nullable
- `is_active` boolean NOT NULL DEFAULT true

RLS: only admins can INSERT/UPDATE. GRANT SELECT/INSERT/UPDATE/DELETE TO authenticated.
→ Safe to upsert from an authenticated admin session without service_role.

---

## Task 1: SQL Migration — `can_email_register` RPC

**Files:**
- Create: `supabase/migrations/20260510030000_add_can_email_register_rpc.sql`

- [ ] **Step 1: Create the migration file**

```sql
-- Adds public.can_email_register(p_email text) → boolean
-- Called by Register.tsx (anon context) before creating a Supabase auth account.
-- Returns true when the given email is allowed to register given the current
-- site_access_mode.  Returns only a boolean — no enumeration risk.
CREATE OR REPLACE FUNCTION public.can_email_register(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(trim(p_email));
  v_mode  text;
BEGIN
  IF v_email IS NULL OR v_email = '' THEN
    RETURN true;
  END IF;

  SELECT site_access_mode INTO v_mode FROM public.settings LIMIT 1;
  v_mode := COALESCE(v_mode, 'private');

  IF v_mode = 'public' THEN
    RETURN true;
  END IF;

  IF v_mode = 'private' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.access_whitelist
      WHERE lower(email) = v_email AND is_active = true
    );
  END IF;

  -- controlled: whitelist OR accepted waitlist
  RETURN EXISTS (
    SELECT 1 FROM public.access_whitelist
    WHERE lower(email) = v_email AND is_active = true
  ) OR EXISTS (
    SELECT 1 FROM public.waitlist
    WHERE lower(email) = v_email AND status = 'accepted'
  );
END;
$$;

COMMENT ON FUNCTION public.can_email_register(text) IS
  'Returns true when the given email is allowed to register under the current site_access_mode. Safe for anon callers — returns only boolean.';

GRANT EXECUTE ON FUNCTION public.can_email_register(text) TO anon, authenticated;
```

- [ ] **Step 2: Apply migration to production DB**

```bash
supabase db push --linked
```

Expected output: migration `20260510030000_add_can_email_register_rpc` applied successfully.

- [ ] **Step 3: Smoke-test the function via Supabase SQL editor**

Run each of these queries in the Supabase dashboard SQL editor:

```sql
-- Should return false (no entry in whitelist, assuming private mode):
SELECT public.can_email_register('nobody@example.com');

-- Should return true (public mode check — temporarily):
UPDATE public.settings SET site_access_mode = 'public';
SELECT public.can_email_register('nobody@example.com');  -- expect true
UPDATE public.settings SET site_access_mode = 'private'; -- restore

-- Should return true for a known whitelisted email:
SELECT public.can_email_register('ludovic.ousselin@gmail.com');
```

- [ ] **Step 4: Commit migration**

```bash
git add supabase/migrations/20260510030000_add_can_email_register_rpc.sql
git commit -m "feat(db): add can_email_register RPC — boolean gate for closed-mode signup"
```

---

## Task 2: AdminLaunchPage.tsx — Upsert Whitelist on Waitlist Accept

**Files:**
- Modify: `src/pages/admin/AdminLaunchPage.tsx` lines 1169–1193

The existing `updateStatus()` only updates `waitlist.status`. This task extends it to also upsert `access_whitelist` after a successful acceptance, with differentiated error handling for partial failures.

- [ ] **Step 1: Replace `updateStatus` (lines 1169–1193)**

Replace the entire function body with:

```typescript
const updateStatus = async (id: string, status: 'accepted' | 'rejected') => {
  setActioningId(id);
  const patch =
    status === 'accepted'
      ? { status, accepted_at: new Date().toISOString() }
      : { status };

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { error } = await (supabase as any).from('waitlist').update(patch).eq('id', id);

  if (error) {
    toast.error('Erreur lors de la mise à jour.');
    console.error('[AdminLaunch] waitlist update error', error);
    setActioningId(null);
    return;
  }

  setRows((prev) =>
    prev.map((r) => (r.id === id ? { ...r, ...patch } : r)),
  );

  if (status !== 'accepted') {
    toast.success('Entrée refusée.');
    setActioningId(null);
    return;
  }

  // After waitlist accept: also upsert access_whitelist so private mode works
  const row = rows.find((r) => r.id === id);
  if (!row) {
    toast.success('Accès accordé.');
    setActioningId(null);
    return;
  }

  const normalizedEmail = row.email.toLowerCase().trim();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { error: wlError } = await (supabase as any)
    .from('access_whitelist')
    .upsert(
      { email: normalizedEmail, is_active: true, granted_at: new Date().toISOString() },
      { onConflict: 'email' },
    );

  if (wlError) {
    console.error('[AdminLaunch] whitelist upsert error', wlError);
    toast.error(
      "Demande acceptée, mais l'ajout à la whitelist a échoué. Vérifiez manuellement la whitelist.",
      { duration: 8000 },
    );
  } else {
    toast.success('Accès accordé et email ajouté à la whitelist.');
  }

  setActioningId(null);
};
```

**Key differences from original:**
- Early return after `error` (avoids state update on failure)
- Rejection path exits before whitelist logic
- Whitelist upsert uses `onConflict: 'email'` — no duplicates, re-activates if is_active was false
- Partial failure shows 8-second warning toast, not a success

- [ ] **Step 2: Verify old `updateStatus` is fully replaced**

Confirm lines 1169–1193 no longer contain the original `toast.success(status === 'accepted' ? 'Accès accordé.' : 'Entrée refusée.')` one-liner.

- [ ] **Step 3: Commit**

```bash
git add src/pages/admin/AdminLaunchPage.tsx
git commit -m "fix(admin): waitlist accept now upserts access_whitelist for private mode compatibility"
```

---

## Task 3: Register.tsx — Pre-Signup Access Gate

**Files:**
- Modify: `src/pages/auth/Register.tsx` (line ~10 for import, line ~127 for check)

- [ ] **Step 1: Add supabase client import**

After the existing imports (around line 10), add:

```typescript
import { supabase } from '../../lib/supabase/client';
```

Exact insertion — add it after the `useToast, useToastStore` import line:

```typescript
// existing line:
import { useToast, useToastStore } from '../../lib/toast';
// add below:
import { supabase } from '../../lib/supabase/client';
```

- [ ] **Step 2: Add access check in `handleSubmit` before `signUp()`**

Current code at lines ~127–133:
```typescript
    try {
      const result = await signUp({
        email: formData.email.trim(),
        password: formData.password,
        username: formData.username.trim(),
        captchaToken: captchaTokenRef.current,
      });
```

Replace with:
```typescript
    try {
      // Guard: block signup if site is closed and email not authorized
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data: canRegister, error: accessError } = await (supabase as any)
        .rpc('can_email_register', { p_email: formData.email.trim() });

      if (!accessError && canRegister === false) {
        toast.error(
          "Votre accès n'a pas encore été validé. Faites une demande depuis la page d'ouverture ou attendez la validation administrateur.",
          5000,
        );
        return;
      }
      // If accessError: fail-open — let signUp handle it; do not block legitimate users

      const result = await signUp({
        email: formData.email.trim(),
        password: formData.password,
        username: formData.username.trim(),
        captchaToken: captchaTokenRef.current,
      });
```

**Why fail-open on RPC error:** If the RPC call itself fails (network timeout, function not deployed yet), we do not want to block legitimate users. `signUp()` will still enforce any server-side validation.

**Why generic message:** Does not reveal whether the email is in the whitelist or not — only says access hasn't been validated.

- [ ] **Step 3: Commit**

```bash
git add src/pages/auth/Register.tsx
git commit -m "fix(auth): block signup in closed mode if email not authorized via can_email_register RPC"
```

---

## Task 4: Validation

- [ ] **Step 1: TypeScript typecheck**

```bash
npm run typecheck
```

Expected: 0 errors. If errors appear in AdminLaunchPage.tsx or Register.tsx, they will be type errors on the `(supabase as any)` cast — the cast is intentional and matches the existing pattern in the file.

- [ ] **Step 2: Lint**

```bash
npm run lint
```

Expected: no new errors. The two `// eslint-disable-next-line @typescript-eslint/no-explicit-any` comments added above suppress the expected any-cast warnings.

- [ ] **Step 3: Manual test — Waitlist → Whitelist (admin)**

Prerequisites: site in **private** mode (`UPDATE public.settings SET site_access_mode = 'private'`).

1. Add a test email to waitlist with status='pending':
   ```sql
   INSERT INTO public.waitlist (email, status, source) VALUES ('test-patch@example.com', 'pending', 'test');
   ```
2. In AdminLaunchPage, go to the Waitlist tab → Pending. Find the entry.
3. Click "Accepter".
4. **Expected:** Toast "Accès accordé et email ajouté à la whitelist."
5. Verify in Supabase:
   ```sql
   SELECT * FROM public.access_whitelist WHERE email = 'test-patch@example.com';
   -- expect: 1 row, is_active=true
   ```
6. Click "Accepter" again (duplicate test):
   - **Expected:** Same success toast, no duplicate row in access_whitelist.

7. Add another entry and click "Refuser":
   - **Expected:** Toast "Entrée refusée.", no row inserted in access_whitelist.

- [ ] **Step 4: Manual test — Register gate**

Prerequisites: site in **private** mode.

A. Email **not** in whitelist or waitlist:
   1. Go to `/register`, enter `blocked@example.com`.
   2. Fill form, solve captcha, submit.
   3. **Expected:** Toast with generic "Votre accès n'a pas encore été validé…" message. No Supabase auth account created.

B. Email **in whitelist** (`is_active=true`):
   1. Insert: `INSERT INTO public.access_whitelist (email) VALUES ('allowed@example.com');`
   2. Go to `/register`, enter `allowed@example.com`.
   3. **Expected:** Registration proceeds to email confirmation page normally.

C. Site in **public** mode:
   1. `UPDATE public.settings SET site_access_mode = 'public';`
   2. Go to `/register` with any email.
   3. **Expected:** Registration proceeds normally without gate message.
   4. Restore: `UPDATE public.settings SET site_access_mode = 'private';`

D. Site in **controlled** mode with email having `waitlist.status='accepted'`:
   1. `UPDATE public.settings SET site_access_mode = 'controlled';`
   2. Insert: `INSERT INTO public.waitlist (email, status, source) VALUES ('waitlisted@example.com', 'accepted', 'test');`
   3. Go to `/register`, enter `waitlisted@example.com`.
   4. **Expected:** Registration proceeds normally.
   5. Restore mode.

- [ ] **Step 5: Manual test — uweboomin@gmail.com trial (verification only, no code change)**

Run in Supabase SQL editor:
```sql
SELECT
  up.is_producer_active,
  up.is_founding_producer,
  up.founding_trial_start,
  up.producer_campaign_type,
  private.is_in_active_trial(up.id) AS trial_active
FROM public.user_profiles up
JOIN auth.users au ON au.id = up.id
WHERE lower(au.email) = 'uweboomin@gmail.com';
```

**Expected:**
- `is_producer_active = false` (manual fix already applied)
- `is_founding_producer = true`
- `founding_trial_start` is set
- `trial_active = true` (if still within 3-month window)

Also verify via the view:
```sql
SELECT can_access_producer_features, founding_trial_active
FROM public.my_user_profile
-- run as the uweboomin user session, or use:
WHERE id = (SELECT id FROM auth.users WHERE lower(email) = 'uweboomin@gmail.com');
```

**Expected:** `can_access_producer_features = true` during trial period.

---

## Post-Patch Compliance Checklist

After all tasks complete, verify:

- [ ] In private mode: admin accepting waitlist → user can register (whitelist upsert confirmed)
- [ ] In private mode: unknown email → `/register` shows generic blocked message
- [ ] In controlled mode: accepted waitlist email → can register
- [ ] In public mode: any email → can register
- [ ] Rejection: no access_whitelist row created
- [ ] Existing whitelisted users: not affected (upsert is idempotent)
- [ ] Stripe flow: not touched — `is_producer_active` only set via Stripe webhook
- [ ] Trial producer (uweboomin): `is_producer_active=false`, `can_access_producer_features=true`
- [ ] `typecheck` passes with 0 errors
- [ ] `lint` passes with 0 new errors
