# Schéma de la base WhatsApp Desktop (macOS)

> Établi à partir de `diagnose.py report` exécuté le 2026-10-07 sur le Mac de Xavier.
> Aucune donnée réelle dans ce document : noms de colonnes, comptages et exemples inventés.
>
> Légende : **constaté** = lu dans le rapport ; **hypothèse** = déduit, à confirmer.

## Environnement

- macOS 26.6.2, WhatsApp 26.40.16 (`net.whatsapp.WhatsApp`, app native Core Data).
- Base : `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`
  (67 Mo) en mode WAL. Le `-wal` (7 Mo) contient les écritures récentes non fusionnées :
  **il faut le copier avec la base**, sinon les derniers messages manquent.
- Autres bases présentes dans le même dossier, non utilisées : `ContactsV2.sqlite`,
  `LID.sqlite` (correspondance LID ↔ numéro, probablement), `Axolotl.sqlite` (clés).

## Autorisations macOS

- **Constaté** : depuis l'app Claude (onglet Code), lister le dossier, copier les trois
  fichiers et ouvrir la copie a fonctionné **sans accès complet au disque** et sans
  boîte de dialogue.
- **À tester** : le même script lancé depuis Terminal.app. C'est ce test qui dira ce
  que l'app DistiX devra demander (accès complet au disque, ou rien). Une app tierce
  peut aussi déclencher la demande « … souhaite accéder aux données d'autres apps »
  de macOS 15+.

## Tables utiles

Entités Core Data : `WAChatSession`, `WAMessage`, `WAGroupInfo`, `WAGroupMember`,
`WAMediaItem`, `WAMessageInfo`, `WAProfilePushName`, et d'autres non utiles ici.

| Table | Rôle | Colonnes utiles |
|---|---|---|
| `ZWACHATSESSION` | une ligne par conversation | `Z_PK`, `ZCONTACTJID`, `ZPARTNERNAME` (nom affiché), `ZSESSIONTYPE`, `ZGROUPINFO`, `ZLASTMESSAGEDATE`, `ZMESSAGECOUNTER`, `ZREMOVED`, `ZHIDDEN`, `ZARCHIVED`, `ZFLAGS` |
| `ZWAMESSAGE` | une ligne par message | `Z_PK`, `ZCHATSESSION`, `ZMESSAGEDATE`, `ZISFROMME`, `ZMESSAGETYPE`, `ZGROUPEVENTTYPE`, `ZTEXT`, `ZSTANZAID`, `ZGROUPMEMBER`, `ZFROMJID`, `ZMEDIAITEM`, `ZMESSAGEINFO`, `ZPUSHNAME`, `ZFLAGS` |
| `ZWAGROUPMEMBER` | membres, par groupe | `Z_PK`, `ZCHATSESSION`, `ZMEMBERJID`, `ZCONTACTNAME`, `ZFIRSTNAME`, `ZISADMIN`, `ZISACTIVE` |
| `ZWAPROFILEPUSHNAME` | nom de profil choisi par chaque contact | `ZJID`, `ZPUSHNAME` |
| `ZWAMEDIAITEM` | médias **et métadonnées de tout message** | `ZMESSAGE`, `ZMETADATA` (protobuf), `ZTITLE`, `ZMEDIALOCALPATH`, `ZFILESIZE` |
| `ZWAMESSAGEINFO` | accusés et réactions | `ZMESSAGE`, `ZRECEIPTINFO` (protobuf) |
| `ZWAGROUPINFO` | infos de groupe | `ZCHATSESSION`, `ZCREATIONDATE`, `ZCREATORJID`, `ZSTATE` |

`ZWAMESSAGE.ZPARENTMESSAGE` existe mais est **toujours nul** : ce n'est pas le lien
de réponse.

## Conversations

**Constaté** (`ZSESSIONTYPE` × suffixe du JID) :

| `ZSESSIONTYPE` | JID | Sens |
|---|---|---|
| 0 | `@s.whatsapp.net`, `@lid` | conversation individuelle |
| 1 | `@g.us` | groupe |
| 2 | `@broadcast` | liste de diffusion |
| 3 | `@status`, `@lid.status` | statuts |
| 4 | `@g.us` | **hypothèse** : groupe d'annonces d'une communauté |
| 5 | `@newsletter` | chaîne |

Un groupe se reconnaît au suffixe `@g.us` du `ZCONTACTJID` (292 groupes chez Xavier).

## Dates

**Constaté** : `ZMESSAGEDATE` est en **secondes depuis le 1er janvier 2001 UTC** (époque
Core Data), en nombre flottant. Conversion : `unix = valeur + 978307200`, puis heure
locale. Les bornes obtenues (2017 → aujourd'hui) sont cohérentes. **Validé par Xavier
le 2026-10-07** : sur les 30 derniers messages d'un groupe, les textes, heures, auteurs,
réponses et réactions affichés par `diagnose.py messages` correspondent à l'app
(vérification globale, pas message par message).

## Profondeur d'historique

**Constaté** : l'historique réel commence en **avril 2025** (environ 1 000 à 2 500
messages de groupe par mois depuis). Avant cette date, il ne reste que quelques messages
isolés (1 à 10 par mois, 2017-2025). **Hypothèse** : avril 2025 correspond à la
liaison de WhatsApp Desktop sur ce Mac, et l'app ne récupère pas l'historique antérieur.

Conséquence : le critère « 3 mois d'historique » de la phase 1 est largement atteignable
(18 mois disponibles sur les groupes actifs). En revanche, un nouvel utilisateur ne
retrouvera que ce que son app Desktop a synchronisé.

## Types de messages (`ZMESSAGETYPE`)

| Valeur | Sens | Constat (groupes) | Traitement prévu |
|---|---|---|---|
| 0 | texte | `ZTEXT` toujours renseigné | analysé |
| 7 | lien avec aperçu | `ZTEXT` toujours renseigné | analysé, lien conservé |
| 8 | document | `ZTEXT` (légende) 77 % | marqueur `[document : titre]` + légende |
| 1 | image | pas de `ZTEXT` | marqueur `[image]` |
| 2 | vidéo | pas de `ZTEXT` | marqueur `[vidéo]` |
| 3 | audio / vocal | pas de `ZTEXT` | marqueur `[vocal]` |
| 4 | contact | | marqueur |
| 5 | position | | marqueur |
| 11 | GIF | | marqueur |
| 15 | sticker | | ignoré ou marqueur |
| 6 | système (arrivées, départs, changements) | `ZGROUPEVENTTYPE` ≠ 2 | écarté |
| 10 | entrée sans contenu : appel de groupe ou notification (**hypothèse**) ; un groupe d'annonces en contenait 54 sur 57, sans texte ni média | `ZGROUPEVENTTYPE` = 3 le plus souvent | écarté, exclu du décompte des groupes |
| 14 | message supprimé | `ZTEXT` presque toujours vide | écarté |
| 12, 13, 46, 54, 59, 66, 75 | **inconnus** (moins de 150 au total ; 46 est peut-être un sondage) | pas de `ZTEXT` | marqueur générique, à préciser |

Sens des valeurs : **hypothèse** tirée de la documentation existante sur WhatsApp iOS, et
cohérente avec les colonnes renseignées. Les légendes des images et vidéos ne sont pas
dans `ZTEXT` : à chercher dans `ZMETADATA` en phase 1 si besoin.

`ZGROUPEVENTTYPE` vaut 2 pour un message ordinaire, d'autres valeurs (1, 3, 4, 7, 9,
12, 15, 26, 35, 42, 50, 58, 60) pour les événements.

## Auteur d'un message de groupe

**Constaté** :

- `ZWAMESSAGE.ZFROMJID` vaut **le JID du groupe** (`@g.us`), pas celui de l'auteur.
- L'auteur est donné par `ZWAMESSAGE.ZGROUPMEMBER` → `ZWAGROUPMEMBER.Z_PK`, renseigné
  pour 99 % des messages reçus. Son `ZMEMBERJID` est surtout un **`@lid`** (identifiant
  anonyme WhatsApp), parfois un `@s.whatsapp.net` (numéro).
- `ZWAGROUPMEMBER.ZCONTACTNAME` est **toujours une chaîne vide** (10 944 sur 10 944).
  `ZFIRSTNAME` est renseigné pour 1 106 membres.
- `ZWAMESSAGE.ZPUSHNAME` **n'est pas un nom**. C'est un protobuf encodé en base64 qui
  contient presque uniquement des entiers (champs 1, 4, 9, 18, 30, 43…) : des
  métadonnées du message. Le champ 7, présent dans 1 % des cas seulement, contient du
  texte de sens inconnu. Cette colonne n'est pas utilisée.
- `ZWAPROFILEPUSHNAME` associe un JID au **nom de profil** choisi par la personne.
  Seuls 830 des 6 781 membres distincts (12 %) y figurent. Mais ce sont les membres
  actifs : cette table couvre **84 % des messages reçus**.

Résolution constatée sur les 5 groupes les plus actifs (2 000 derniers messages reçus
chacun) :

| Source du nom | Part des messages |
|---|---|
| `ZWAPROFILEPUSHNAME[ZMEMBERJID]` | 84 % |
| `ZWAGROUPMEMBER.ZFIRSTNAME` | 3 % |
| aucune (JID brut) | 13 % |

Ordre retenu : `ZCONTACTNAME` non vide → `ZFIRSTNAME` → `ZWAPROFILEPUSHNAME[ZMEMBERJID]`
→ JID. Les 13 % sans nom ne gênent pas le pipeline, qui travaille sur des alias. Pour
afficher les vrais noms, on pourra explorer en phase 1 `ContactsV2.sqlite` et
`LID.sqlite`. Les noms de profil sont libres : une seule lettre, des emoji, des doublons
entre personnes sont possibles.

Sur les 30 derniers messages du groupe le plus actif, tous les auteurs sont résolus.
On y trouve 3 noms distincts, stables d'un message à l'autre.

**Identifiant stable de l'auteur** : `ZMEMBERJID`. **Risque** : une même personne peut
apparaître sous un `@lid` et sous un `@s.whatsapp.net`. `LID.sqlite` permettrait
probablement de les rapprocher (non exploré).

**Mentions** : dans `ZTEXT`, une mention s'écrit `@` suivi d'un numéro de 15 chiffres
environ (partie utilisateur du LID ou numéro de téléphone), pas d'un nom. On en compte
651 dans les groupes. La pseudonymisation devra
les remplacer par l'alias du membre.

## Lien « réponse à »

**Constaté, exploitable.** Il est dans **`ZWAMEDIAITEM.ZMETADATA`**, un blob protobuf.
Chaque message texte a une ligne `ZWAMEDIAITEM`, pas seulement les médias.

- **champ 5** : identifiant (`ZSTANZAID`) du message cité ;
- **champ 6** : JID de l'auteur du message cité ;
- **champ 4** (hypothèse) : extrait du texte cité.

Chiffres :
- 2 901 des 17 260 messages texte de groupe (17 %) citent un message présent en base.
- 13 citent un message absent de la base (antérieur à l'historique).
- Les médias en réponse ont la même structure.

Dans les 30 derniers messages du groupe le plus actif, les 2 réponses détectées pointent
vers le bon message.

Exemple de structure (valeurs inventées) : `ZMETADATA = {5: "3A1B2C…", 6: "1234@lid", …}`.

## Réactions

**Constaté, exploitable.** Elles sont dans **`ZWAMESSAGEINFO.ZRECEIPTINFO`** (protobuf),
**champ 7** :

- `7.1` : une entrée par réaction. On y trouve `7.1.2` (JID de l'auteur de la
  réaction), `7.1.3` (emoji) et `7.1.4` (horodatage, hypothèse).
- `7.2` : une autre structure qui contient aussi un emoji (103 cas). Son sens est inconnu.

3 955 messages de groupe ont au moins une réaction, pour 6 479 réactions au total. C'est un signal d'approbation
utilisable pour les réponses.

## Réglage « export du chat bloqué »

**Non trouvé.** Aucune colonne explicite dans `ZWAGROUPINFO` ni dans
`ZWACHATPROPERTIES` (table vide). La seule piste est un bit de `ZWACHATSESSION.ZFLAGS`.
Les valeurs constatées sont 272, 67109136, 256, 524560, 67111184… Le bit `0x4000000`
(67108864) distingue un sous-ensemble de 256 conversations.

Pour trancher, il faut un groupe dont Xavier **sait** que l'export est bloqué : lancer
`diagnose.py chat-props` dessus et sur un groupe normal, puis comparer.

## Validation de schéma retenue pour le connecteur

Colonnes obligatoires (arrêt propre si absentes) :

- `ZWACHATSESSION` : `Z_PK`, `ZCONTACTJID`, `ZPARTNERNAME` ;
- `ZWAMESSAGE` : `Z_PK`, `ZCHATSESSION`, `ZTEXT`, `ZMESSAGEDATE`, `ZISFROMME`,
  `ZMESSAGETYPE`.

À ajouter pour la phase 1 :

- colonnes : `ZWAMESSAGE.ZSTANZAID`, `ZWAMESSAGE.ZGROUPMEMBER`,
  `ZWAGROUPMEMBER.ZMEMBERJID`, `ZWAMEDIAITEM.ZMESSAGE`, `ZWAMEDIAITEM.ZMETADATA` ;
- un **contrôle de vraisemblance** : si plus de quelques pourcents des réponses ne se
  décodent plus via le champ 5, signaler un changement de format, même si les colonnes
  sont intactes.

## Noms et numéros : LID.sqlite et ContactsV2.sqlite (constaté le 2026-10-07)

- `LID.sqlite`, table `ZWAZACCOUNT` : une ligne par compte. `ZIDENTIFIER` = JID `…@lid` complet (les 5 786
  membres @lid des groupes s'y retrouvent tous), `ZDISPLAYNAME` (3 368 renseignés), `ZPHONENUMBER`
  (renseigné pour 57 % des membres), `ZCURRENTPHONENUMBERSHARINGSTATE` : 0 sans numéro = 2 505,
  0 avec numéro = 2 766, 1 avec numéro = 515 (1 ne va jamais sans numéro). Sens exact **non documenté**.
- `ContactsV2.sqlite`, table `ZWAADDRESSBOOKCONTACT` : le carnet d'adresses (772 contacts), avec `ZLID`,
  `ZWHATSAPPID`, `ZFULLNAME` (nom saisi par l'utilisateur) et `ZPHONENUMBER`.
- Règle retenue (choix de Xavier : « seulement si partagé ») : numéro affiché pour un contact du carnet, un membre
  adressé par son numéro (`@s.whatsapp.net`), ou un compte d'état 1. Interprétation prudente : l'état 0 avec
  numéro n'est pas affiché. Les numéros ne sont jamais envoyés à l'IA.
- Ces deux bases sont facultatives pour le connecteur : illisibles ou modifiées, on continue sans noms ni numéros.

## Points restant ouverts à la fin de la phase 0

- Autorisation macOS nécessaire quand le script est lancé hors de l'app Claude (test
  depuis Terminal.app).
- Réglage « export bloqué » : non identifié.
- Types de message rares (12, 13, 46, 54, 59, 66, 75) : sens inconnu.
- Mentions `@<numéro>` : à relier au membre mentionné (via `ZMEMBERJID`) en phase 1.
- Doublons `@lid` / `@s.whatsapp.net` pour une même personne : non mesurés.
