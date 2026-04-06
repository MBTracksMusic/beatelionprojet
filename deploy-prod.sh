#!/bin/bash

set -euo pipefail

echo "🚀 Déploiement PRODUCTION"

EXPECTED_VERCEL_PROJECT="beatelion-production"

# =========================
# LOAD ENV
# =========================
if [ ! -f ".env.production" ]; then
  echo "❌ Fichier .env.production introuvable"
  exit 1
fi

set -o allexport
source .env.production
set +o allexport

echo "🌍 ENVIRONMENT: ${ENVIRONMENT:-undefined}"
echo "📡 SUPABASE_PROJECT_REF: ${SUPABASE_PROJECT_REF:-undefined}"

# =========================
# CHECK TOOLS
# =========================
for cmd in git node npm supabase vercel jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Commande manquante : $cmd"
    exit 1
  fi
done

# =========================
# SAFE CHECKS
# =========================
if [ "${ENVIRONMENT:-}" != "production" ]; then
  echo "❌ ENVIRONMENT doit être égal à production"
  exit 1
fi

if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
  echo "❌ SUPABASE_PROJECT_REF manquant"
  exit 1
fi

# 🔴 Protection ENV sensible
if git status --porcelain | grep ".env" >/dev/null; then
  echo "❌ Modification .env détectée — commit manuel requis"
  exit 1
fi

# =========================
# AUTO COMMIT SAFE
# =========================
if [[ -n "$(git status -s)" ]]; then
  echo "⚠️ Repo non clean — auto-commit sécurisé"

  # Ajoute uniquement fichiers déjà suivis
  git add -u

  # Alerte sur fichiers non suivis
  UNTRACKED=$(git ls-files --others --exclude-standard)
  if [[ -n "$UNTRACKED" ]]; then
    echo "⚠️ Fichiers non suivis ignorés :"
    echo "$UNTRACKED"
  fi

  git commit -m "chore: auto-commit before production deploy" || true
fi

# =========================
# GIT FLOW (AUTO MERGE → MAIN)
# =========================
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "📌 Branche actuelle : $CURRENT_BRANCH"

if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "⚠️ Tu n'es pas sur main"

  read -p "👉 Fusionner '$CURRENT_BRANCH' → main ? (y/n): " confirm_merge

  if [ "$confirm_merge" != "y" ]; then
    echo "❌ Déploiement annulé"
    exit 1
  fi

  git fetch origin

  echo "🔄 Checkout main..."
  git checkout main
  git pull origin main

  echo "🔀 Merge $CURRENT_BRANCH → main"
  git merge "$CURRENT_BRANCH" --no-ff

  echo "🚀 Push main..."
  git push origin main
fi

# =========================
# CHECK CLEAN APRÈS MERGE
# =========================
if [[ -n "$(git status -s)" ]]; then
  echo "❌ Repo non clean après merge"
  git status -s
  exit 1
fi

# =========================
# SYNC CHECK
# =========================
git fetch origin

LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u})

if [ "$LOCAL" != "$REMOTE" ]; then
  echo "❌ Branche main non synchronisée avec origin"
  exit 1
fi

# =========================
# VERCEL LINK
# =========================
echo "🔗 Vérification projet Vercel..."

if [ ! -f ".vercel/project.json" ]; then
  vercel link --project "$EXPECTED_VERCEL_PROJECT"
fi

CURRENT_PROJECT_NAME=$(jq -r '.projectName' .vercel/project.json)

if [ "$CURRENT_PROJECT_NAME" != "$EXPECTED_VERCEL_PROJECT" ]; then
  vercel link --project "$EXPECTED_VERCEL_PROJECT"
fi

echo "✅ Projet Vercel OK"

# =========================
# CONFIRMATION HARD
# =========================
echo "⚠️ ATTENTION : DEPLOY PRODUCTION"

read -p "Tape EXACTEMENT 'DEPLOY' pour continuer : " confirm

if [ "$confirm" != "DEPLOY" ]; then
  echo "❌ Annulé"
  exit 1
fi

# =========================
# CHECKS AVANT PROD
# =========================
echo "🔐 Scan sécurité..."
[ -f "./check-secrets.sh" ] && ./check-secrets.sh

echo "🔍 Audit..."
[ -f "./audit.sh" ] && ./audit.sh

echo "🧪 Build..."
npm run build

# =========================
# SUPABASE
# =========================
echo "🔗 Supabase link..."
supabase link --project-ref "$SUPABASE_PROJECT_REF"

echo "📡 DB push..."
supabase db push

echo "⚡ Functions deploy..."
supabase functions deploy --project-ref "$SUPABASE_PROJECT_REF"

# =========================
# PUSH FINAL (si déjà sur main)
# =========================
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "🚀 Push PROD..."
  git push origin main
fi

# =========================
# DONE
# =========================
echo "🎉 DEPLOY PRODUCTION OK"