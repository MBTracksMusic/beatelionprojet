# Supabase Security Checklist (BeatElion)

Ce document couvre les réglages sécurité qui ne sont pas entièrement pilotés par les migrations SQL.

## 1) Leaked Password Protection (Auth)

Objectif: empêcher l'utilisation de mots de passe compromis connus.

Important:
- Ce réglage se fait dans le dashboard Supabase.
- Ce n'est pas activable de façon fiable via migration SQL dans ce repository.

### Étapes dashboard

1. Ouvrir le projet Supabase.
2. Aller dans `Authentication`.
3. Ouvrir la section de configuration mot de passe (selon l'UI: `Providers > Email` ou `Security`).
4. Activer `Leaked password protection`.
5. Sauvegarder la configuration.

### Vérification après activation

1. Créer un compte de test avec un mot de passe connu comme compromis.
2. Vérifier que l'inscription/changement de mot de passe est refusé.
3. Vérifier qu'un mot de passe fort non compromis est accepté.

## 2) Notes d'exploitation

- Activer ce réglage en `staging` puis `production`.
- Conserver les logs d'erreurs d'auth pour confirmer l'effet réel.
- Documenter la date d'activation dans le runbook d'exploitation.
