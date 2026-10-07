# DistiX

App macOS qui transforme les groupes WhatsApp choisis par l'utilisateur en base de
connaissances : une fiche par question, avec les réponses, les accords et les désaccords.
Tout reste en local. Voir [BRIEF.md](BRIEF.md).

## App macOS (phase 2)

Code dans `app/` (paquet Swift, macOS 14+) :

- `DistiXCore` : connecteur WhatsApp, stockage (GRDB, FTS5), fournisseurs d'IA, pipeline, export ;
- `DistiX` : l'app SwiftUI ;
- `distix-cli` : les mêmes fonctions en ligne de commande, pour tester sans l'interface.

```sh
cd app && swift test                  # tests sur base factice
scripts/build-app.sh                  # construit build/DistiX.app (signée ad hoc)
build/DistiX.app/Contents/MacOS/distix-cli groups
```

Fournisseurs d'IA : abonnement Claude via le CLI `claude` (Claude Code), API Anthropic (clé dans
le Trousseau), ou tout serveur compatible OpenAI (Ollama, LM Studio). Les prompts sont dans
`app/Sources/DistiXCore/Resources/prompts/`.

La CI (GitHub Actions, runner macOS) lance les tests et publie `DistiX.zip` en artefact.

## Phase 0 (diagnostic)

`prototype/diagnose.py` lit une **copie** de la base locale de WhatsApp Desktop, en lecture
seule, avec la seule bibliothèque standard Python.

```sh
python3 prototype/diagnose.py report            # rapport sans contenu, partageable
python3 prototype/diagnose.py groups            # liste des groupes (local)
python3 prototype/diagnose.py messages "nom"    # 30 derniers messages (local)
python3 prototype/diagnose.py chat-props "nom"  # réglages d'un groupe, pour comparaison
```

Tests sur base factice :

```sh
python3 -m unittest discover -s prototype/tests -t .
```

Aucune donnée réelle n'est versionnée : tout ce qui est produit va dans `data/`, ignoré par git.
