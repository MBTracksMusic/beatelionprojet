#!/bin/bash

set -euo pipefail

echo "🚀 Déploiement PRODUCTION"

# =========================
# CONFIG
# =========================
EXPECTED_VERCEL_PROJECT="beatelion-production"

# =========================
# 0. LOAD ENV
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
# 1. CHECK TOOLS
# =========================
for cmd in git node npm supabase vercel jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Commande manquante : $cmd"
    exit 1
  fi
done

# =========================
# 2. SAFE CHECKS
# =========================
if [ "${ENVIRONMENT:-}" != "production" ]; then
  echo "❌ ENVIRONMENT doit être égal à production"
  exit 1
fi

if [ -z "${SUPABASE_PROJECT_REF:-}" ]; then
  echo "❌ SUPABASE_PROJECT_REF manquant"
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "❌ Déploiement autorisé uniquement depuis main"
  exit 1
fi

# 🔴 Vérifie que main est propre
if [[ -n "$(git status -s)" ]]; then
  echo "❌ Repo non clean — commit avant deploy"
  exit 1
fi

# 🔴 Vérifie que main est à jour
git fetch origin

LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u})

if [ "$LOCAL" != "$REMOTE" ]; then
  echo "❌ Branche main non synchronisée avec origin"
  exit 1
fi

# =========================
# 3. VERCEL LINK
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
# 4. CONFIRMATION HARD
# =========================
echo "⚠️ ATTENTION : DEPLOY PRODUCTION"

read -p "Tape EXACTEMENT 'DEPLOY' pour continuer : " confirm

if [ "$confirm" != "DEPLOY" ]; then
  echo "❌ Annulé"
  exit 1
fi

# =========================
# 5. CHECKS AVANT PROD
# =========================
echo "🔐 Scan sécurité..."
[ -f "./check-secrets.sh" ] && ./check-secrets.sh

echo "🔍 Audit..."
[ -f "./audit.sh" ] && ./audit.sh

echo "🧪 Build..."
npm run build

# =========================
# 6. SUPABASE
# =========================
echo "🔗 Supabase link..."
supabase link --project-ref "$SUPABASE_PROJECT_REF"

echo "📡 DB push..."
supabase db push

echo "⚡ Functions deploy..."
supabase functions deploy --project-ref "$SUPABASE_PROJECT_REF"

# =========================
# 7. DEPLOY PROD (GIT ONLY)
# =========================
echo "🚀 Push PROD (trigger Vercel)..."
git push origin main

echo "🎉 DEPLOY PRODUCTION OK"