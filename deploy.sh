#!/bin/bash

set -e

echo "🚀 Déploiement intelligent en cours..."

# =========================
# 0. CHECK CHANGEMENTS
# =========================
if [[ -z $(git status -s) ]]; then
  echo "✅ Aucun changement détecté. Déploiement inutile."
  exit 0
fi

# =========================
# 1. CHECK SECRETS (important)
# =========================
if [ -f "./check-secrets.sh" ]; then
  echo "🔐 Scan sécurité..."
  ./check-secrets.sh || exit 1
fi

# =========================
# 2. COMMIT PROPRE
# =========================
echo "📦 Commit & Push Git..."

read -p "📝 Message de commit: " commit_message

if [ -z "$commit_message" ]; then
  commit_message="auto: deploy update"
fi

git add -u
git add .
git commit -m "$commit_message"
git push origin main

# =========================
# 3. BUILD CHECK
# =========================
echo "🧪 Vérification build..."

npm run build

echo "✅ Build OK"

# =========================
# 4. SUPABASE DB
# =========================
echo "🧠 Vérification migrations..."

if git diff --name-only HEAD~1 | grep -q "supabase/migrations"; then
  echo "📡 Déploiement DB..."
  supabase db push
else
  echo "✅ Aucune migration détectée."
fi

# =========================
# 5. EDGE FUNCTIONS
# =========================
echo "⚡ Vérification functions..."

if git diff --name-only HEAD~1 | grep -q "supabase/functions"; then
  echo "🚀 Déploiement des fonctions..."
  supabase functions deploy
else
  echo "✅ Aucune fonction modifiée."
fi

# =========================
# 6. VERCEL
# =========================
echo "🌐 Déploiement frontend..."
vercel --prod

echo "🎉 Déploiement intelligent terminé !"