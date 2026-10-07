# DistiX

App macOS qui transforme les groupes WhatsApp choisis par l'utilisateur en base de
connaissances : une fiche par question, avec les réponses, les accords et les désaccords.
Tout reste en local. Voir [BRIEF.md](BRIEF.md).

## État : phase 0 (diagnostic)

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
