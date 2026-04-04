/*
  # Atomic producer subscription → user_profiles sync

  ## Problème résolu
  Double écriture : le webhook écrivait directement dans user_profiles (role, producer_tier,
  is_producer_active, stripe_subscription_id) ET un trigger faisait de même depuis
  producer_subscriptions (is_producer_active seulement). Race condition possible si deux
  webhooks Stripe arrivent simultanément.

  ## Architecture cible
  - Le webhook écrit UNIQUEMENT dans producer_subscriptions (incluant producer_tier)
  - Le trigger est la SEULE source qui met à jour user_profiles (atomique, pas de course)

  ## Changements
  1. Ajoute producer_tier à producer_subscriptions
  2. Back-fill depuis user_profiles
  3. Remplace sync_user_profile_producer_flag() pour tout syncer atomiquement
  4. Recrée le trigger

  ## Compatibilité
  - Aucun nom de table modifié
  - Aucune donnée supprimée
  - Les migrations précédentes ne sont pas affectées
*/

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Ajouter producer_tier à producer_subscriptions
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.producer_subscriptions
  ADD COLUMN IF NOT EXISTS producer_tier public.producer_tier_type
    NOT NULL
    DEFAULT 'user'::public.producer_tier_type;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Back-fill : aligner les lignes existantes depuis user_profiles
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE public.producer_subscriptions ps
SET producer_tier = COALESCE(up.producer_tier, 'user'::public.producer_tier_type)
FROM public.user_profiles up
WHERE ps.user_id = up.id
  AND up.producer_tier IS NOT NULL
  AND ps.producer_tier IS DISTINCT FROM up.producer_tier;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Remplacer la fonction trigger par la version complète
--    Source unique de vérité : producer_subscriptions → user_profiles
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sync_user_profile_producer_flag()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_role text;
  v_next_role    text;
BEGIN
  -- Lire le rôle actuel pour gérer le cas admin et l'activation
  SELECT role INTO v_current_role
  FROM public.user_profiles
  WHERE id = NEW.user_id;

  -- Déterminer le prochain rôle
  -- Logique identique à l'ancienne logique du webhook :
  --   activation  → passer à 'producer' (sauf admin)
  --   désactivation → on conserve le rôle (is_producer_active=false bloque l'accès en pratique)
  IF NEW.is_producer_active AND v_current_role IS DISTINCT FROM 'admin' THEN
    v_next_role := 'producer';
  ELSE
    v_next_role := v_current_role;  -- pas de changement (annulation conserve 'producer')
  END IF;

  -- Mise à jour atomique de user_profiles — aucune autre écriture ne doit toucher ces champs
  UPDATE public.user_profiles
  SET
    is_producer_active     = NEW.is_producer_active,
    producer_tier          = NEW.producer_tier,
    stripe_subscription_id = NEW.stripe_subscription_id,
    -- Ne pas écraser un stripe_customer_id déjà présent
    stripe_customer_id     = COALESCE(stripe_customer_id, NEW.stripe_customer_id),
    role                   = v_next_role,
    updated_at             = now()
  WHERE id = NEW.user_id;

  RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Recréer le trigger (même nom, déjà existant)
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_sync_user_profile_producer ON public.producer_subscriptions;

CREATE TRIGGER trg_sync_user_profile_producer
  AFTER INSERT OR UPDATE ON public.producer_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_user_profile_producer_flag();

COMMIT;
