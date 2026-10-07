# Brief projet : base de connaissances à partir de groupes WhatsApp (app Mac)

Nom retenu : **DistiX** (nom de code initial : Filon).

Ce document est le brief de départ pour Claude Code. Il décrit le besoin, les décisions déjà prises, l'architecture cible, le découpage en phases et les critères d'acceptation. Les points marqués **[À VÉRIFIER]** sont des hypothèses non validées : il faut les contrôler par inspection réelle avant de coder dessus.

---

## 1. Le besoin

Dans les groupes WhatsApp à thème professionnel (exemple réel : une communauté d'investisseurs immobiliers), beaucoup de savoir circule sous forme de questions et de réponses, mais il est éparpillé : quelqu'un pose une question, d'autres répondent, entre-temps d'autres questions arrivent, des gens rebondissent plus tard. Suivre demande de tout lire et de prendre des notes à la main, ce qui prend un temps considérable.

L'objectif est une app Mac qui :

1. récupère automatiquement les nouveaux messages des groupes choisis par l'utilisateur ;
2. reconstitue les fils de discussion entremêlés ;
3. produit une fiche par question : la question, son contexte, les réponses apportées, les points d'accord et de désaccord ;
4. fusionne les questions qui reviennent plusieurs fois dans une même fiche qui s'enrichit ;
5. classe les fiches par thème et les rend cherchables ;
6. signale ce qui est nouveau ou mis à jour, et le retire des nouveautés une fois lu.

Le travail est du résumé et du classement, plus que du filtrage de bruit : dans ces groupes, il y a peu de bavardage, mais beaucoup de sujets croisés.

**Utilisateurs de la V1** : Xavier (développeur du projet) puis sa sœur Aurélia, non technique. L'app doit donc être configurable sans toucher au code. Une diffusion plus large (5 à 10 testeurs, puis éventuellement vente en achat unique ou open source) sera décidée plus tard : ne rien construire pour ça maintenant, mais ne rien faire qui l'empêche.

---

## 2. Décisions déjà prises

| Sujet | Décision |
|---|---|
| Source des messages | Lecture **en lecture seule** de la base SQLite locale de WhatsApp Desktop sur Mac |
| Pas d'API non officielle | Ne pas utiliser Baileys, whatsmeow, whatsapp-web.js ni aucun "appareil lié" (risque de bannissement, contraire aux CGU) |
| Plateforme | macOS uniquement, app native Swift/SwiftUI |
| Tout-en-un | La base de connaissances, les nouveautés et la configuration vivent dans l'app. Pas de Notion ni de Discord en V1 |
| Export | Bouton d'export Markdown (compatible import Notion) et copie d'une fiche |
| Stockage | SQLite local, rien dans le cloud, pas de compte, pas de backend |
| IA | Fournisseur interchangeable. V1 avec clé API saisie par l'utilisateur. IA locale à évaluer ensuite |
| Périmètre de lecture | Uniquement les groupes cochés par l'utilisateur (liste blanche) |
| Distribution | Hors Mac App Store (app non sandboxée), signée Developer ID et notarisée |

---

## 3. Hors périmètre de la V1

- Envoyer des messages ou écrire quoi que ce soit dans les données de WhatsApp.
- App iPhone, synchro iCloud.
- Intégrations Notion, Discord, Slack.
- Autres messageries (Telegram, iMessage, Signal) : prévues par l'architecture (section 6.1), pas implémentées.
- Abonnement, paiement, licences, backend.
- Transcription des messages vocaux, analyse des images et documents.
- Chatbot conversationnel sur la base (une recherche suffit en V1).

---

## 4. Source de données : la base locale WhatsApp

### 4.1 Emplacement

```
~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite
```

Cet emplacement est confirmé par plusieurs outils open source existants (par exemple `wa-chat-reader` sur PyPI). Des fichiers `-wal` et `-shm` l'accompagnent.

### 4.2 Schéma **[À VÉRIFIER]**

C'est une base Core Data. D'après mes connaissances (non contrôlées sur la version actuelle de l'app), les tables utiles seraient :

- `ZWACHATSESSION` : une ligne par conversation. Colonnes probables : `Z_PK`, `ZCONTACTJID` (identifiant, se termine par `@g.us` pour un groupe), `ZPARTNERNAME` (nom affiché), `ZSESSIONTYPE`.
- `ZWAMESSAGE` : une ligne par message. Colonnes probables : `Z_PK`, `ZCHATSESSION` (clé vers la conversation), `ZTEXT`, `ZMESSAGEDATE`, `ZISFROMME`, `ZFROMJID`, `ZPUSHNAME`, `ZGROUPMEMBER`, `ZMESSAGETYPE`, `ZSTANZAID`.
- `ZWAGROUPMEMBER` : membres des groupes (pour retrouver l'auteur d'un message de groupe).
- `ZWAMEDIAITEM` : métadonnées des médias.

Points à établir par introspection (`PRAGMA table_info`, échantillons de lignes) :

- les noms exacts des tables et colonnes ;
- le format de `ZMESSAGEDATE` (probablement des secondes depuis le 1er janvier 2001, époque Core Data, à convertir) ;
- **où est stocké le lien "réponse à"** (message cité). C'est une information précieuse pour reconstituer les fils. Elle peut se trouver dans une colonne de `ZWAMESSAGE`, dans `ZWAMEDIAITEM` ou dans un blob de métadonnées ;
- comment distinguer messages texte, médias, messages système (arrivées, départs, changements de nom) et messages supprimés ;
- si les réactions emoji sont stockées (utile comme signal d'approbation d'une réponse) ;
- quelle profondeur d'historique est réellement présente dans la base.

**Règle** : ne jamais coder en supposant ce schéma. Le script de la phase 0 doit l'établir, et le rapport de phase 0 fait foi.

### 4.3 Règles d'accès (non négociables)

1. **Jamais d'écriture** dans le dossier de WhatsApp. Aucune exception.
2. Copier `ChatStorage.sqlite` et ses fichiers `-wal` et `-shm` dans un dossier temporaire, puis ouvrir **la copie** en lecture seule. Supprimer la copie après lecture.
3. Ne lire que les lignes des conversations en liste blanche (filtre SQL sur la clé de conversation). Les autres conversations ne doivent jamais être chargées en mémoire, sauf leur nom dans l'écran de sélection des groupes.
4. Au démarrage et avant chaque synchro, **valider le schéma attendu** (tables et colonnes requises). S'il a changé, arrêter proprement avec un message clair, sans rien corrompre : une mise à jour de WhatsApp peut modifier la base à tout moment.
5. Isoler tout le code qui connaît le schéma WhatsApp dans un seul module (le connecteur), pour qu'une évolution du schéma ne touche qu'un fichier.

### 4.4 Autorisations macOS **[À VÉRIFIER]**

L'accès au Group Container d'une autre app est protégé par macOS. Il faudra probablement l'un des deux mécanismes suivants, à tester : l'accès complet au disque accordé à l'app dans Réglages Système, ou une sélection explicite du dossier par l'utilisateur avec mémorisation par signet (security-scoped bookmark). Retenir le moins intrusif qui fonctionne, et guider l'utilisateur pas à pas dans l'onboarding.

### 4.5 Limite connue

La base locale ne se remplit que lorsque WhatsApp Desktop est ouvert. Si le Mac est resté éteint, l'app WhatsApp rattrape les messages à son lancement **[À VÉRIFIER : fiabilité et délai]**. Prévoir une option "ouvrir WhatsApp avant la synchro" et afficher la date du dernier message connu par groupe, pour que l'utilisateur voie un éventuel retard.

---

## 5. Découpage en phases

Travailler phase par phase. **À la fin de chaque phase, s'arrêter, résumer les résultats et attendre la validation de Xavier avant de continuer.**

### Phase 0 : diagnostic (Python, un seul script)

But : prouver que la lecture de la base fonctionne et documenter le schéma réel.

Livrables :

- `prototype/diagnose.py` qui : localise la base, la copie, liste tables et colonnes utiles, liste les groupes (nom, nombre de messages, date du premier et du dernier message), affiche les 30 derniers messages d'un groupe choisi en argument.
- `docs/schema-whatsapp.md` : le schéma constaté, le format des dates, l'emplacement du lien "réponse à", les types de messages, les autorisations macOS qui ont été nécessaires.

Critères d'acceptation :

- le script tourne sur le Mac de Xavier sans modifier un seul fichier de WhatsApp ;
- les messages affichés correspondent à ceux visibles dans l'app (texte, auteur, heure locale correcte) ;
- tous les points **[À VÉRIFIER]** de la section 4 ont une réponse écrite.

### Phase 1 : prototype du pipeline (Python, ligne de commande)

But : juger la qualité des fiches sur de vraies conversations avant d'investir dans l'app. C'est la phase qui décide si le projet vaut la peine.

Livrables :

- un outil en ligne de commande : `python -m prototype.run --group "<nom>" --since 2026-07-01` qui produit un dossier de fiches Markdown et un fichier `fiches.json` ;
- synchro incrémentale : un second lancement ne retraite que les nouveaux messages et met à jour les fiches existantes ;
- un court rapport `docs/evaluation-phase1.md` (voir section 9).

Pourquoi en Python : itérer sur les prompts et la logique est beaucoup plus rapide qu'en Swift. Les prompts, les schémas JSON et les seuils retenus seront repris tels quels en phase 2.

Critères d'acceptation :

- sur un groupe réel de Xavier, au moins 3 mois d'historique traités de bout en bout ;
- Xavier relit 30 fiches et juge la majorité fidèles et utiles (grille en section 9) ;
- coût et durée de traitement mesurés et notés.

### Phase 2 : app macOS (Swift/SwiftUI)

But : la même logique dans une app utilisable par une personne non technique.

Livrables : l'app décrite en sections 6 à 8, avec onboarding, synchro automatique, nouveautés, recherche, export.

Critères d'acceptation :

- installation et configuration complètes par Aurélia, sans aide, en moins de 10 minutes ;
- synchro automatique fonctionnelle pendant une semaine sans intervention ;
- une mise à jour simulée du schéma (colonne renommée dans une base de test) produit un message d'erreur clair, sans plantage ni perte de données.

### Phase 3 : plus tard, sur décision

IA locale, connecteur Telegram, signature et notarisation pour diffusion, modèle économique.

---

## 6. Architecture

### 6.1 Connecteurs de source

Chaque messagerie est un module derrière une interface commune. Seul WhatsApp est implémenté, mais rien d'autre dans l'app ne doit connaître WhatsApp.

```swift
protocol MessageSource {
    var id: String { get }                       // "whatsapp"
    func checkAvailability() async throws -> SourceStatus
    func listConversations() async throws -> [SourceConversation]
    func fetchMessages(in conversation: String,
                       after cursor: SyncCursor?) async throws -> [SourceMessage]
}

struct SourceMessage {
    let sourceId: String          // identifiant stable du message dans la source
    let conversationId: String
    let authorId: String          // identifiant stable de l'auteur
    let authorDisplayName: String?
    let sentAt: Date
    let text: String?
    let kind: MessageKind         // text, media, system, deleted
    let replyToSourceId: String?  // si la source le fournit
}
```

Le curseur de synchro est par conversation : date et identifiant du dernier message traité.

### 6.2 Pipeline de traitement

```
Source -> Normalisation -> Pseudonymisation -> Attribution aux fils
       -> Rédaction des fiches -> Fusion des doublons -> Thèmes -> Stockage
```

**1. Normalisation.** Écarter les messages système et supprimés. Remplacer les médias par un marqueur (`[image]`, `[vocal]`, `[document : nom.pdf]`) : ils ne sont pas analysés mais leur présence aide à comprendre le fil. Conserver les liens.

**2. Pseudonymisation.** Avant tout appel à un modèle, remplacer les noms d'auteurs par des alias stables par groupe (`Membre 12`) et masquer numéros de téléphone et e-mails présents dans le texte. La table de correspondance reste en local. Les noms réels ne sont réaffichés que dans l'interface, si l'utilisateur l'a activé. Réglage par défaut : pseudonymisation activée.

**3. Attribution aux fils.** C'est la partie difficile.

- Traiter les nouveaux messages par fenêtres chronologiques (taille à régler, par exemple 60 à 100 messages) avec un recouvrement.
- Fournir au modèle : les messages de la fenêtre (identifiant court, alias, heure, texte, lien "réponse à" si disponible) et la liste des **fils ouverts** (identifiant, question résumée en une ligne, derniers messages).
- Le modèle renvoie en JSON, pour chaque message : le fil existant auquel il se rattache, ou la création d'un nouveau fil, ou `aucun` (remerciement, hors sujet, bavardage).
- Un lien "réponse à" explicite prime sur l'avis du modèle.
- Un fil reste ouvert N jours après son dernier message (valeur de départ : 7), pour capter les réponses tardives. Ensuite il est clos, mais un message ultérieur peut encore s'y rattacher par la fusion (étape 5).

**4. Rédaction des fiches.** Pour chaque fil créé ou modifié, générer ou régénérer la fiche (schéma en 6.3) à partir de tous ses messages. Consignes au modèle :

- ne rien inventer : chaque réponse listée doit s'appuyer sur des messages cités par identifiant ;
- distinguer ce qui fait consensus, ce qui est contesté, ce qui reste sans réponse ;
- rédiger dans la langue de la conversation ;
- rester concis : la fiche doit se lire en moins d'une minute ;
- une question sans aucune réponse donne une fiche au statut `sans_reponse`.

**5. Fusion des doublons.** Calculer un embedding de la question de chaque fiche. Pour une nouvelle fiche, chercher les plus proches dans le même groupe (puis, en option, entre groupes). Au-dessus d'un seuil de similarité, demander confirmation au modèle ("ces deux questions portent-elles sur le même sujet ?") avant de fusionner. La fusion regroupe les fils sous une seule fiche, régénérée à partir de l'ensemble. Garder la trace des fils d'origine pour pouvoir défaire une fusion.

**6. Thèmes.** Chaque fiche reçoit un thème principal parmi une liste propre à chaque groupe. La liste est proposée par le modèle au premier traitement, puis stable : un nouveau thème n'est créé que si aucun ne convient. L'utilisateur peut renommer et fusionner les thèmes.

**7. Statut de lecture.** Une fiche créée est "nouvelle". Une fiche régénérée avec du contenu nouveau (réponse supplémentaire, fusion) redevient non lue, avec l'étiquette "mise à jour" et l'indication de ce qui a changé. Une simple reformulation sans contenu nouveau ne doit pas la repasser en non lue.

### 6.3 Schéma d'une fiche

```json
{
  "id": "uuid",
  "group_id": "…",
  "theme": "Financement",
  "status": "repondue | debattue | sans_reponse",
  "question": "Faut-il attendre d'avoir vendu avant de chercher le bien suivant ?",
  "context": "Deux à trois phrases sur la situation de la personne qui demande.",
  "answers": [
    {
      "summary": "Continuer à sourcer pendant les travaux pour ne pas avoir de trou d'activité.",
      "support": "consensus | avis_isole | conteste",
      "source_message_ids": ["…", "…"]
    }
  ],
  "disagreements": ["Résumé d'un point de désaccord, si présent."],
  "open_points": ["Ce qui reste sans réponse."],
  "links": ["https://…"],
  "first_message_at": "2026-09-12T08:41:00Z",
  "last_message_at": "2026-09-14T19:02:00Z",
  "thread_ids": ["…"],
  "updated_at": "…",
  "read_at": null
}
```

### 6.4 Fournisseurs d'IA

Deux interfaces séparées, pour pouvoir mélanger (par exemple embeddings locaux et génération cloud) :

```swift
protocol LLMProvider {
    func generate<T: Decodable>(_ request: LLMRequest, as type: T.Type) async throws -> T
}
protocol EmbeddingProvider {
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

- **V1** : API Anthropic avec clé saisie par l'utilisateur, plus un fournisseur générique "compatible OpenAI" avec URL configurable (ce qui couvre d'emblée Ollama et LM Studio en local, sans code supplémentaire).
- Le nom du modèle est un réglage, pas une constante. Par défaut, un petit modèle rapide et bon marché pour l'attribution aux fils, avec la possibilité d'en choisir un plus capable pour la rédaction des fiches. Vérifier les identifiants de modèles actuels dans la documentation au moment de coder.
- Sorties structurées en JSON, validées contre un schéma, avec une nouvelle tentative en cas de JSON invalide.
- Embeddings : évaluer d'abord une solution locale (framework NaturalLanguage d'Apple en français **[À VÉRIFIER : qualité]**, ou un petit modèle via le fournisseur local). Sinon, API.
- Clés API stockées dans le Trousseau, jamais dans un fichier ni dans les journaux.
- Afficher dans les réglages une estimation du coût du dernier traitement (jetons consommés).

### 6.5 Stockage local

SQLite via GRDB.swift, dans `~/Library/Application Support/<AppName>/`. Tables :

| Table | Rôle |
|---|---|
| `conversations` | Groupes connus : source, identifiant source, nom, `selected`, curseur de synchro |
| `messages` | Messages des groupes sélectionnés uniquement : identifiant source, auteur, date, texte, type, lien de réponse |
| `authors` | Correspondance identifiant réel, nom affiché, alias |
| `threads` | Fils : groupe, état (ouvert, clos), résumé d'une ligne, dates |
| `thread_messages` | Rattachement message vers fil |
| `fiches` | Contenu JSON de la fiche, thème, statut, embedding, `updated_at`, `read_at` |
| `fiche_threads` | Fils regroupés dans une fiche (pour défaire une fusion) |
| `themes` | Thèmes par groupe |
| `sync_runs` | Journal des synchros : date, messages lus, fiches créées et mises à jour, jetons, erreurs |

Recherche plein texte avec FTS5 sur question, contexte et réponses. Migrations versionnées dès le départ.

Décocher un groupe propose de supprimer toutes ses données locales (messages, fils, fiches).

### 6.6 Planification

- Synchro au lancement de l'app, puis toutes les X heures (réglage, 3 heures par défaut), et sur demande.
- Lancement à l'ouverture de session via `SMAppService`, activable dans les réglages.
- Une synchro ne doit jamais en chevaucher une autre. En cas d'échec en cours de route (réseau, quota), elle reprend là où elle s'était arrêtée sans créer de doublons : le curseur n'avance qu'après écriture réussie.

---

## 7. Interface

### 7.1 Onboarding (3 écrans)

1. **Accès à WhatsApp** : vérifier que WhatsApp Desktop est installé et connecté, guider l'octroi de l'autorisation, confirmer que la base est lisible.
2. **Choix des groupes** : liste des groupes détectés avec nombre de messages et date du dernier, cases à cocher, choix de la profondeur d'historique à traiter (1 mois, 3 mois, 6 mois, tout). Afficher une estimation du coût et de la durée du premier traitement avant de lancer.
3. **IA** : choix du fournisseur, saisie de la clé, bouton "tester la connexion". Expliquer en une phrase claire ce qui quitte le Mac : le texte des messages des groupes choisis, pseudonymisé, envoyé au fournisseur d'IA sélectionné, et rien d'autre.

### 7.2 Fenêtre principale

Disposition en trois colonnes (`NavigationSplitView`) :

- **Barre latérale** : "Nouveautés" avec compteur, puis chaque groupe avec son compteur de non lus, dépliable en thèmes.
- **Liste** : fiches avec question, statut, thème, date, pastille "nouveau" ou "mis à jour". Tri par date, filtre par statut.
- **Détail** : la fiche complète. Bouton pour afficher les messages sources (avec alias ou noms réels selon le réglage). Actions : copier en Markdown, exporter, marquer comme non lue, corriger le thème, défaire une fusion.

Une fiche est marquée lue à l'ouverture. Bouton "tout marquer comme lu" dans Nouveautés.

Recherche globale dans la barre d'outils.

### 7.3 Barre de menus

Icône avec compteur de non lus. Menu : dernière synchro, "Synchroniser maintenant", "Ouvrir", accès aux réglages.

### 7.4 Notifications

Désactivées par défaut. Si activées : **une seule notification par synchro** ("4 nouvelles questions, 2 fiches mises à jour"), jamais une par fiche.

### 7.5 Export

- Une fiche : copie Markdown dans le presse-papiers, ou fichier `.md`.
- Un groupe ou toute la base : dossier de fichiers Markdown, un par fiche, rangés par thème, avec un en-tête simple (titre, thème, dates) pour un import propre dans Notion ou Obsidian.

### 7.6 Langue

Interface en français, chaînes externalisées dès le départ pour pouvoir traduire.

---

## 8. Pile technique

**Prototype (phases 0 et 1)**

- Python 3.11+, module `sqlite3` standard, SDK Anthropic, `numpy` pour la similarité. Pas de framework, pas de base vectorielle externe.

**App (phase 2)**

- Swift, SwiftUI, cible macOS 14 minimum.
- GRDB.swift pour SQLite. Éviter toute autre dépendance lourde.
- App non sandboxée, Hardened Runtime activé, prête pour signature Developer ID et notarisation.
- La logique (connecteur, pipeline, stockage, fournisseurs) vit dans un package Swift séparé de l'interface, testable sans lancer l'app.

**Arborescence proposée**

```
/
├─ BRIEF.md
├─ docs/
│  ├─ schema-whatsapp.md
│  └─ evaluation-phase1.md
├─ prototype/            # Python, phases 0 et 1
│  ├─ diagnose.py
│  ├─ run.py
│  ├─ source_whatsapp.py
│  ├─ pipeline/
│  └─ prompts/           # prompts en fichiers texte, repris tels quels en phase 2
├─ app/                  # projet Xcode, phase 2
│  ├─ FilonApp/          # interface SwiftUI
│  └─ Packages/FilonCore/
│     ├─ Sources/        # Sources (connecteurs), Pipeline, Storage, Providers
│     └─ Tests/
└─ data/                 # ignoré par git : copies de base, sorties, exports
```

---

## 9. Évaluation de la qualité (phase 1)

Le rapport `docs/evaluation-phase1.md` doit contenir :

- le volume traité (messages, fils, fiches, fusions), la durée et le coût en jetons ;
- la relecture par Xavier de 30 fiches tirées au hasard, notées sur quatre critères :
  1. **Fidélité** : la fiche ne dit rien qui ne soit dans les messages ;
  2. **Complétude** : aucune réponse importante n'a été oubliée ;
  3. **Découpage** : le fil regroupe les bons messages, ni trop ni trop peu ;
  4. **Utilité** : la fiche remplace la lecture des messages d'origine ;
- la liste des erreurs typiques constatées et les ajustements faits (taille de fenêtre, durée d'ouverture des fils, seuil de fusion, consignes des prompts) ;
- un test d'incrémental : traiter jusqu'à une date, puis la suite, et comparer avec un traitement d'une seule traite. Les résultats doivent être proches.

Pour faciliter la relecture, chaque fiche Markdown du prototype inclut en annexe les messages sources.

---

## 10. Confidentialité et garde-fous

- Liste blanche stricte : aucun message d'une conversation non cochée n'est lu, stocké ou envoyé.
- Pseudonymisation activée par défaut avant tout appel à un modèle.
- Aucune télémétrie, aucun envoi de données autre que les appels au fournisseur d'IA choisi.
- Les journaux ne contiennent jamais de texte de message ni de clé.
- **Ne jamais commiter de données réelles** : `data/`, toute copie de base, toute sortie de prototype et tout export sont dans `.gitignore` dès le premier commit. Les tests utilisent une base factice générée par un script.
- L'app rappelle à l'utilisateur, à la sélection des groupes, que ces conversations contiennent les messages d'autres personnes et que l'usage est personnel.

---

## 11. Risques connus

| Risque | Réponse prévue |
|---|---|
| WhatsApp modifie ou chiffre sa base locale | Validation du schéma à chaque synchro, connecteur isolé, message d'erreur clair. Le connecteur par export manuel (.zip) reste une solution de repli à ajouter si besoin |
| La base locale n'est pas à jour (app WhatsApp fermée) | Option d'ouverture de WhatsApp avant synchro, affichage du dernier message connu par groupe |
| Qualité insuffisante de la reconstitution des fils | C'est l'objet de la phase 1. Ne pas commencer l'app tant que ce n'est pas validé |
| Coût du premier traitement sur un gros historique | Estimation affichée avant lancement, profondeur d'historique au choix |
| macOS durcit l'accès aux données des autres apps | Tester sur la version courante de macOS en phase 0, documenter l'autorisation nécessaire |

---

## 12. Questions ouvertes (à remonter à Xavier, ne pas trancher seul)

1. Le lien "réponse à" est-il exploitable dans la base ? Si non, quel est l'impact mesuré sur la qualité des fils ?
2. Certains groupes ont un réglage de confidentialité qui bloque l'export du chat. Ce réglage est-il visible dans la base ? Si oui, l'app devrait exclure ces groupes par défaut, par respect du choix des administrateurs.
3. Faut-il fusionner les questions similaires **entre** groupes, ou seulement à l'intérieur d'un groupe ?
4. Les noms réels des auteurs doivent-ils pouvoir s'afficher dans l'interface, ou rester toujours sous alias ?
5. Quel modèle local donne une qualité acceptable, et sur quelle configuration de Mac ?
6. Nom définitif de l'app.

---

## 13. Consignes de travail pour Claude Code

1. Commencer par la **phase 0 uniquement**. Ne pas créer le projet Xcode avant la validation de la phase 1.
2. S'arrêter à la fin de chaque phase avec un résumé : ce qui marche, ce qui a été constaté, ce qui reste incertain.
3. Ne jamais écrire dans le dossier de WhatsApp. Travailler sur une copie.
4. Ne rien supposer du schéma : l'inspecter, le documenter, puis coder.
5. Garder les prompts dans des fichiers séparés et versionnés, pas dans le code.
6. Écrire des tests pour le connecteur (sur base factice), l'incrémental et la fusion.
7. Pour toute décision produit non couverte ici, poser la question plutôt que choisir.
