# Producer Earnings Fallback Test Plan

## Objectif
Valider que `ProducerEarnings` reste fonctionnel quand `producer_revenue_view` est absente, tout en gardant une UX propre et un signal d'observabilite emis une seule fois par session.

## Prerequis
- Frontend lance localement ou environnement de staging accessible.
- Un compte producteur avec au moins une vente `completed`.
- Acces a la base locale/staging si vous testez la methode A.
- Variable de session navigateur nettoyable entre deux tests si necessaire.

## Methode A - Test reel avec vue absente
1. Supprimer ou renommer temporairement `public.producer_revenue_view` en local ou staging.
2. Ouvrir `/producer/earnings` avec un compte producteur.
3. Verifier que les donnees s'affichent via le fallback.
4. Recharger la page dans le meme onglet puis dans un nouvel onglet de la meme session.
5. Restaurer la vue SQL apres le test.

## Methode B - Test controle via flag DEV
1. Definir `VITE_FORCE_PRODUCER_EARNINGS_FALLBACK=true` dans l'environnement frontend local.
2. Redemarrer le serveur Vite.
3. Ouvrir `/producer/earnings` avec un compte producteur.
4. Verifier que le badge `Limited data mode` apparait meme si la vue existe.
5. Recharger la page dans la meme session pour confirmer l'absence de spam de logs et d'evenements.

## Resultats attendus

### Cas nominal - Vue presente
- Les donnees de revenus s'affichent.
- Aucun badge `Limited data mode`.
- Aucune erreur visible dans l'UI.
- Aucun log fallback emis.

### Cas fallback - Vue absente ou flag active
- Les donnees s'affichent via la requete fallback.
- Le badge `Limited data mode` apparait.
- Un seul warning en dev ou une seule erreur en prod est emis par session.
- Un seul event `producer_earnings_fallback_used` est emis par session.
- Aucune erreur visible dans l'UI.

### Cas erreur fallback
- Si la vue echoue puis que la requete fallback echoue aussi, l'etat d'erreur apparait proprement.
- La page ne crash pas.
- Le message utilisateur reste `Unable to load earnings`.

## Nettoyage
- Supprimer `VITE_FORCE_PRODUCER_EARNINGS_FALLBACK` apres le test.
- Restaurer la vue SQL si elle a ete retiree.
- Vider la session navigateur si vous voulez retester le comportement `once per session`.
