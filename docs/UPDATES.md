# Mises à jour automatiques

Même dispositif que QuiX et InFlow : **Sparkle 2**.

- L'app vérifie une fois par jour `https://github.com/xavierkain-apps/distix/releases/latest/download/appcast.xml`
  (dépôt public : le flux et l'archive sont des fichiers de la dernière release GitHub), affiche les notes de
  version, télécharge, vérifie la signature EdDSA contre `SUPublicEDKey`, installe et relance.
- Menu DistiX > « Rechercher des mises à jour… » et Réglages > Général > Mises à jour.
- Sans clé publique dans l'Info.plist (constructions locales), Sparkle est désactivé.

## Clé

- DistiX réutilise la clé EdDSA de **QuiX** (compte par défaut du trousseau de Xavier), à la demande de Xavier.
  Sa moitié publique est dans `app/sparkle-public-key.txt`, recopiée dans l'Info.plist par `scripts/build-app.sh`.
  (InFlow a sa propre clé, compte « InFlow ».)
- Perdre la clé privée = plus aucune mise à jour possible pour les apps installées. Elle reste dans le trousseau.

## Publier une version (sur le Mac de Xavier)

1. Écrire `release-notes/X.Y.Z.fr.md` et commiter.
2. `scripts/release.sh X.Y.Z` : construction universelle signée **Developer ID** (identité du trousseau),
   notarisation (`notarytool`, profil `inflow-notary` par défaut, `NOTARY_PROFILE` pour un autre), signature
   Sparkle avec la clé du trousseau, `appcast.xml`, tag `vX.Y.Z` et release GitHub.

Pas de GitHub Actions : les minutes de runner macOS sont payantes. La CI ne se lance qu'à la main.

Le numéro de build (`CFBundleVersion`) est le nombre de commits : c'est lui que Sparkle compare. Il ne doit
jamais redescendre.

Une app signée Developer ID garde la même identité d'une version à l'autre : macOS ne redemande plus
l'autorisation d'accéder aux données de WhatsApp à chaque mise à jour, contrairement aux constructions ad hoc.
