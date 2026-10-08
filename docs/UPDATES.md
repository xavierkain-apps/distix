# Mises à jour automatiques

Même dispositif que QuiX et InFlow : **Sparkle 2**.

- L'app vérifie une fois par jour `https://github.com/xavierkain-apps/distix/releases/latest/download/appcast.xml`
  (dépôt public : le flux et l'archive sont des fichiers de la dernière release GitHub), affiche les notes de
  version, télécharge, vérifie la signature EdDSA contre `SUPublicEDKey`, installe et relance.
- Menu DistiX > « Rechercher des mises à jour… » et Réglages > Général > Mises à jour.
- Sans clé publique dans l'Info.plist (constructions locales), Sparkle est désactivé.

## Clés

- Paire EdDSA propre à DistiX, générée sur le Mac de Xavier avec l'outil de Sparkle :
  `generate_keys --account DistiX` (clé privée dans le trousseau), puis
  `generate_keys --account DistiX -x <fichier>` pour l'exporter vers le secret **`SPARKLE_PRIVATE_KEY`** du dépôt.
- La moitié publique est dans `app/sparkle-public-key.txt`, que `scripts/build-app.sh` recopie dans l'Info.plist.
- Perdre la clé privée = plus aucune mise à jour possible pour les apps installées. Elle reste dans le trousseau.

## Publier une version

1. Écrire `release-notes/X.Y.Z.fr.md`.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. La CI (`.github/workflows/ci.yml`, job `app`) : tests, construction universelle signée **Developer ID**
   (certificat partagé avec QuiX : secrets d'organisation `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`,
   `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`), notarisation, signature Sparkle, `appcast.xml`, release GitHub.

Le numéro de build (`CFBundleVersion`) est le nombre de commits : c'est lui que Sparkle compare. Il ne doit
jamais redescendre.

Une app signée Developer ID garde la même identité d'une version à l'autre : macOS ne redemande plus
l'autorisation d'accéder aux données de WhatsApp à chaque mise à jour, contrairement aux constructions ad hoc.
