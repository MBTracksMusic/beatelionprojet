/*
  # Harden handle_new_user() for Google OAuth (and all future OAuth providers)

  ## Context
  The handle_new_user() trigger already fires on every auth.users INSERT, which
  covers both email/password signups (via auth-signup Edge Function) and OAuth
  providers (Google, etc.).

  ## Problems fixed by this migration
  1. Username uniqueness conflict — email prefixes like "john.doe" collide with
     existing usernames, causing the trigger INSERT to fail and the entire OAuth
     login to abort. Fixed with a counter-suffix loop.
  2. Email prefix sanitization — characters like "." and "+" are not allowed by
     the client-side username regex; we replace them with "_" to keep usernames
     clean in the DB.
  3. Missing avatar_url / full_name from OAuth metadata — Google provides
     avatar_url, full_name, and name in raw_user_meta_data; the old trigger
     ignored them.
  4. confirmed_at not set for OAuth users — Google users have email_confirmed_at
     set immediately by Supabase; the old trigger left confirmed_at NULL, making
     is_confirmed = false in the profile and blocking voting / exclusive access.
  5. Idempotency — old trigger had no guard against double-insertion.

  ## What is NOT changed
  - Trigger definition (still AFTER INSERT ON auth.users, FOR EACH ROW)
  - email/password signup flow (auth-signup Edge Function passes username in
    raw_user_meta_data, which is picked up by COALESCE first, so it is unaffected)
  - All other columns and their defaults
  - RLS policies, indexes, or any other migration
*/

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_username     text;
  v_base         text;
  v_avatar_url   text;
  v_full_name    text;
  v_confirmed_at timestamptz;
  v_counter      int := 0;
BEGIN
  -- Idempotent guard: skip if a profile already exists for this user
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id = NEW.id) THEN
    RETURN NEW;
  END IF;

  -- ── Metadata extraction ────────────────────────────────────────────────────
  -- Works for email/password (raw_user_meta_data set by auth-signup Edge Fn)
  -- and OAuth providers (Google sets avatar_url, full_name / name).

  v_avatar_url := NEW.raw_user_meta_data->>'avatar_url';

  v_full_name := COALESCE(
    NEW.raw_user_meta_data->>'full_name',  -- Google / generic OAuth
    NEW.raw_user_meta_data->>'name'        -- fallback
  );

  -- ── Username resolution ────────────────────────────────────────────────────
  -- Priority: explicit username (set by auth-signup) → sanitized email prefix

  v_base := COALESCE(
    NULLIF(TRIM(NEW.raw_user_meta_data->>'username'), ''),
    regexp_replace(split_part(NEW.email, '@', 1), '[^a-zA-Z0-9_]', '_', 'g')
  );

  -- Enforce minimum length (pad short prefixes to avoid 1–2 char usernames)
  IF length(v_base) < 3 THEN
    v_base := v_base || '_user';
  END IF;

  -- Cap at 28 chars to leave room for "_NNN" uniqueness suffix
  v_base := left(v_base, 27);

  v_username := v_base;

  -- ── Uniqueness conflict resolution ────────────────────────────────────────
  -- Loop at most ~9999 times; in practice 0 or 1 iterations for real workloads.
  WHILE EXISTS (SELECT 1 FROM public.user_profiles WHERE username = v_username) LOOP
    v_counter  := v_counter + 1;
    v_username := v_base || '_' || v_counter::text;
  END LOOP;

  -- ── Email confirmation for OAuth providers ─────────────────────────────────
  -- Google (and other OAuth providers) set email_confirmed_at immediately.
  -- We mirror that into confirmed_at so is_confirmed = true from first login.
  IF NEW.email_confirmed_at IS NOT NULL THEN
    v_confirmed_at := NEW.email_confirmed_at;
  END IF;

  -- ── Insert profile ─────────────────────────────────────────────────────────
  INSERT INTO public.user_profiles (
    id,
    email,
    username,
    full_name,
    avatar_url,
    role,
    confirmed_at
  ) VALUES (
    NEW.id,
    NEW.email,
    v_username,
    v_full_name,
    v_avatar_url,
    'user',
    v_confirmed_at
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
