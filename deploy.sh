#!/bin/bash

echo "🚀 Déploiement intelligent en cours..."

# Vérifier s'il y a des changements
if [[ -z $(git status -s) ]]; then
  echo "✅ Aucun changement détecté. Déploiement inutile."
  exit 0
fi

# 1. Git (sécurisé)
echo "📦 Commit & Push Git..."

read -p "📝 Message de commit: " commit_message

git add -u
git add .
git commit -m "$commit_message"
git push origin main

# 2. Supabase DB (uniquement si migration)
if [ -d "supabase/migrations" ]; then
  echo "🧠 Vérification migrations..."
  
  if git diff --name-only HEAD~1 | grep -q "supabase/migrations"; then
    echo "📡 Déploiement DB..."
    supabase db push
  else
    echo "✅ Aucune migration détectée."
  fi
fi

# 3. Edge Functions (uniquement si modifiées)
if git diff --name-only HEAD~1 | grep -q "supabase/functions"; then
  echo "⚡ Déploiement des fonctions modifiées..."
  supabase functions deploy
else
  echo "✅ Aucune fonction modifiée."
fi

# 4. Frontend (Vercel)
echo "🌐 Déploiement frontend..."
vercel --prod

echo "✅ Déploiement intelligent terminé !"