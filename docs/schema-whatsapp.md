# Schéma de la base WhatsApp Desktop (macOS)

> Statut : **à compléter** à partir du rapport `diagnose.py report` exécuté sur le Mac de Xavier.
> Aucune donnée réelle dans ce document : noms de colonnes et exemples inventés uniquement.

## Environnement constaté (2026-10-07)

- macOS 26.6.2, WhatsApp 26.40.16 (`net.whatsapp.WhatsApp`, app native).
- Base : `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`,
  avec `-wal` et `-shm` (mode WAL, le WAL contient les écritures récentes non fusionnées :
  il faut le copier avec la base).
- Le dossier est **listable** depuis l'app Claude (onglet Code) sans accès complet au disque.
  Lecture du contenu et lancement depuis Terminal : à confirmer.

## Points à établir

| Point | Réponse |
|---|---|
| Tables et colonnes utiles | à compléter |
| Format de `ZMESSAGEDATE` | à compléter |
| Lien « réponse à » | à compléter |
| Types de messages (texte, média, système, supprimé) | à compléter |
| Réactions | à compléter |
| Profondeur d'historique | à compléter |
| Réglage « export bloqué » visible ? | à compléter |
| Autorisations macOS nécessaires | à compléter |
