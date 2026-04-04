# Audit cible - Campagne Producteurs / Founding Producers

Date: 2026-04-04

## 1. Résumé exécutif

Le système "Campagne Producteurs" est un système d'activation admin-only.

- Un admin saisit un email dans l'UI admin.
- L'Edge Function résout cet email vers `user_profiles.id`.
- La RPC SQL assigne ensuite l'utilisateur à une campagne.
- L'inscription à la campagne n'est pas stockée dans une table de liaison dédiée.
- L'inscription est stockée directement dans `public.user_profiles`.

Conclusion importante:

- Oui, la personne doit déjà avoir un compte Beatelion pour être activée.
- Non, elle ne s'inscrit pas elle-même à la campagne.
- Oui, l'expiration du trial est automatique.
- Non, la désinscription de la campagne n'est pas automatique.
- Non, il n'existe aujourd'hui ni bouton de retrait, ni RPC officielle de retrait.

## 2. Parcours réel

### Chargement de la carte admin

Le composant admin appelle `admin-get-campaign` au chargement pour récupérer:

- la configuration de la campagne
- la liste des participants
- le compteur de slots utilisés

### Activation d'un producteur

Quand l'admin clique sur "Activer Founding":

1. le frontend envoie `email` ou `user_id` + `campaign_type`
2. l'Edge Function vérifie que l'appelant est admin
3. l'Edge Function cherche l'utilisateur dans `public.user_profiles`
4. la RPC `public.admin_assign_producer_campaign(...)` met à jour le profil
5. le frontend recharge la liste

## 3. Où sont stockées les données

### Table de configuration de campagne

Table: `public.producer_campaigns`

Elle contient:

- `type`
- `label`
- `trial_duration`
- `max_slots`
- `is_active`
- `created_at`

La campagne founding est seedée ici avec:

- `type = 'founding'`
- `label = 'Founding Producers'`
- `trial_duration = interval '3 months'`
- `max_slots = 20`

### Table d'inscription réelle

Table: `public.user_profiles`

Les colonnes de campagne utilisées sont:

- `producer_campaign_type`
- `is_founding_producer`
- `founding_trial_start`
- `role`
- `producer_tier`

Point clé:

- il n'y a pas de table `campaign_participants`
- il n'y a pas de table `producer_campaign_registrations`
- un utilisateur est "inscrit" parce que sa ligne `user_profiles` porte la campagne

Conséquence:

- un utilisateur ne peut avoir qu'une seule campagne producteur à la fois

### Vue calculée côté frontend

Vue: `public.my_user_profile`

Elle calcule:

- `producer_campaign_label`
- `campaign_trial_duration`
- `founding_trial_end`
- `founding_trial_active`
- `founding_trial_expired`
- `can_access_producer_features`

## 4. Est-ce que la personne doit s'inscrire avant

Oui, elle doit déjà exister dans le système avant activation.

Concrètement:

- il faut une ligne dans `auth.users`
- cette création déclenche automatiquement la création ou la réparation de `public.user_profiles`
- l'activation par email recherche uniquement dans `public.user_profiles`

Donc:

- si l'email n'existe pas dans `user_profiles`, l'admin aura `User not found`
- la campagne n'est pas un formulaire d'inscription public
- c'est un assignement manuel par admin

Important:

- je ne vois pas de vérification "email confirmé obligatoire" dans la logique de campagne
- le prérequis réel est l'existence du profil, pas forcément une confirmation email

## 5. Ce que fait exactement l'activation

La RPC `public.admin_assign_producer_campaign(...)` fait ceci:

- vérifie que l'appelant est admin
- vérifie que la campagne existe
- vérifie que la campagne est active
- vérifie le nombre de slots
- vérifie que l'utilisateur existe
- met à jour `user_profiles`

Elle écrit notamment:

- `producer_campaign_type = p_campaign_type`
- `is_founding_producer = true` si campagne `founding`
- `founding_trial_start = p_trial_start` ou conserve la valeur si déjà dans la même campagne
- `role = 'producer'` sauf si l'utilisateur est admin
- `producer_tier = 'pro'`

Elle ne modifie pas:

- `is_producer_active`

Ce champ reste piloté par Stripe.

## 6. Ce qui est automatique

### Automatique

- le calcul de la date de fin du trial
- le statut `founding_trial_active`
- le statut `founding_trial_expired`
- le droit réel d'accès `can_access_producer_features`
- le blocage du checkout producteur si le trial est encore actif

### Non automatique

- la sortie de campagne
- la libération du slot
- la remise à zéro de `producer_campaign_type`
- la remise à zéro de `is_founding_producer`
- la remise à zéro de `founding_trial_start`
- la remise à zéro de `producer_tier`

## 7. Est-ce que les slots se libèrent automatiquement

Non.

Aujourd'hui, le compteur de slots prend tous les profils dont:

- `producer_campaign_type = 'founding'`

Le système ne filtre pas sur:

- trial actif
- trial expiré

Donc un participant expiré reste:

- visible dans la liste admin
- compté dans les slots
- rattaché à la campagne en base

Conclusion métier:

- l'expiration retire l'accès
- l'expiration ne retire pas l'inscription

## 8. Comment enlever quelqu'un aujourd'hui

### Ce qui existe aujourd'hui

Il n'existe pas de:

- bouton admin de retrait
- Edge Function de retrait
- RPC `admin_remove_producer_campaign`
- tâche automatique de nettoyage

### Retrait minimal pour libérer un slot

Le retrait minimal consiste à effacer les champs de campagne dans `public.user_profiles`.

Ce retrait doit être fait:

- soit depuis le SQL Editor Supabase avec les droits admin/service role
- soit via une future RPC dédiée

Il ne peut pas être confié au frontend tel quel, car les colonnes de campagne sont protégées.

Exemple SQL minimal:

```sql
update public.user_profiles
set
  producer_campaign_type = null,
  is_founding_producer = false,
  founding_trial_start = null,
  updated_at = now()
where email = 'producteur@beatelion.com';
```

Pourquoi ces 3 champs ensemble:

- `producer_campaign_type` porte l'inscription actuelle
- `is_founding_producer` doit retomber à `false`
- `founding_trial_start` doit redevenir `null`

Sinon la cohérence des champs founding peut devenir incorrecte.

### Ce que ce retrait minimal NE fait PAS

Il ne remet pas automatiquement:

- `role`
- `producer_tier`
- `is_producer_active`

Et c'est volontaire:

- `is_producer_active` est piloté par Stripe
- le système ne stocke pas l'état "avant activation"
- donc il n'existe pas aujourd'hui de rollback métier fiable pour `role` et `producer_tier`

## 9. Risque important au retrait manuel

L'activation de campagne force:

- `role = 'producer'`
- `producer_tier = 'pro'`

Si on retire seulement la campagne:

- le slot est libéré
- le trial est coupé
- mais le profil peut garder un rôle/tier producteur

Ce n'est pas forcément bloquant pour l'accès principal, car l'accès réel s'appuie surtout sur:

- `can_access_producer_features`
- `is_producer_active`

Mais cela peut laisser des effets secondaires:

- affichage du tier producteur
- accès avancés dépendants du tier
- incohérence de profil

Conclusion:

- pour un vrai retrait propre, il faut une RPC dédiée de désassignation
- cette RPC doit décider comment recalculer `role` et `producer_tier`

## 10. Réponse claire à tes questions

### Comment ça fonctionne

C'est un système admin qui assigne manuellement un utilisateur existant à une campagne producteur.

### Où les personnes sont inscrites

Dans `public.user_profiles`, principalement via:

- `producer_campaign_type`
- `is_founding_producer`
- `founding_trial_start`

### Est-ce qu'elles doivent s'inscrire avant

Oui, elles doivent d'abord avoir un compte Beatelion, car l'activation cherche leur email dans `public.user_profiles`.

### Est-ce que l'inscription est automatique

Non. L'inscription à la campagne est manuelle côté admin.

### Est-ce que la fin du trial est automatique

Oui. Le trial expire automatiquement par calcul SQL.

### Est-ce que le retrait est automatique

Non. Le retrait de campagne et la libération du slot ne sont pas automatiques.

## 11. Recommandation produit / technique

Le système actuel fonctionne pour "activer" mais pas pour "retirer proprement".

Le prochain vrai besoin devrait être:

1. une RPC `admin_unassign_producer_campaign(p_user_id uuid)`
2. une Edge Function `admin-unassign-campaign`
3. un bouton "Retirer" dans l'UI admin
4. une règle métier explicite pour le rollback de `role` et `producer_tier`

Sans ça, le retrait restera manuel et partiellement ambigu.
