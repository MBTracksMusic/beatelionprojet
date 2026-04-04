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

# =========================
# 3. VERCEL LINK FORCE
# =========================
echo "🔗 Vérification projet Vercel..."

if [ ! -f ".vercel/project.json" ]; then
  echo "⚠️ Aucun projet Vercel lié → linking..."
  vercel link --project "$EXPECTED_VERCEL_PROJECT"
fi

CURRENT_PROJECT_NAME=$(jq -r '.projectName' .vercel/project.json)

echo "👉 Projet actuel : $CURRENT_PROJECT_NAME"

if [ "$CURRENT_PROJECT_NAME" != "$EXPECTED_VERCEL_PROJECT" ]; then
  echo "⚠️ Mauvais projet détecté → re-link..."
  vercel link --project "$EXPECTED_VERCEL_PROJECT"
fi

# Vérification finale
FINAL_PROJECT_NAME=$(jq -r '.projectName' .vercel/project.json)

if [ "$FINAL_PROJECT_NAME" != "$EXPECTED_VERCEL_PROJECT" ]; then
  echo "❌ Impossible de lier au bon projet Vercel"
  exit 1
fi

echo "✅ Projet Vercel OK : $FINAL_PROJECT_NAME"

# =========================
# 4. CONFIRMATION
# =========================
read -p "⚠️ CONFIRMER DEPLOY PROD (yes): " confirm
if [ "$confirm" != "yes" ]; then
  echo "❌ Annulé"
  exit 1
fi

# =========================
# 5. CHECK SECRETS
# =========================
if [ -f "./check-secrets.sh" ]; then
  echo "🔐 Scan sécurité..."
  ./check-secrets.sh
fi

# =========================
# 6. AUDIT
# =========================
if [ -f "./audit.sh" ]; then
  ./audit.sh || exit 1
fi

# =========================
# 7. BUILD
# =========================
echo "🧪 Build..."
npm run build

# =========================
# 8. COMMIT SI BESOIN
# =========================
if [[ -n "$(git status -s)" ]]; then
  git add -A
  git commit -m "auto: prod deploy" || true
  git push origin main
fi

# =========================
# 9. SUPABASE
# =========================
echo "🔗 Supabase link..."
supabase link --project-ref "$SUPABASE_PROJECT_REF"

echo "📡 DB push..."
supabase db push

echo "⚡ Functions deploy..."
supabase functions deploy --project-ref "$SUPABASE_PROJECT_REF"

# =========================
# 10. VERCEL DEPLOY
# =========================
echo "🌐 Deploy Vercel PROD..."
vercel --prod

echo "🎉 DEPLOY PRODUCTION OK"