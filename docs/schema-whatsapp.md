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
locale. Les bornes obtenues (2017 → aujourd'hui) sont cohérentes, et les heures
affichées correspondent plausiblement à l'heure locale (**à confirmer par Xavier** en
comparant avec l'app).

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
| 10 | appel de groupe | `ZGROUPEVENTTYPE` = 3 | écarté |
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
- `ZWAGROUPMEMBER.ZCONTACTNAME` n'est jamais nul, mais **semble souvent vide**. Dans les
  30 messages testés, aucun nom n'a été trouvé par cette voie.
- `ZWAMESSAGE.ZPUSHNAME` **n'est pas un nom en clair**. C'est une chaîne de 36 caractères
  qui ressemble à du base64, différente à chaque message. **Hypothèse** : un protobuf
  encodé en base64, ou une valeur chiffrée.
- `ZWAPROFILEPUSHNAME` (1 654 entrées) associe un JID au nom de profil : c'est la source
  de nom la plus prometteuse.

Ordre de résolution retenu (à valider par le second rapport) :
`ZWAGROUPMEMBER.ZCONTACTNAME` non vide → `ZFIRSTNAME` → `ZWAPROFILEPUSHNAME[ZMEMBERJID]`
→ `ZPUSHNAME` décodé → JID brut.

**Identifiant stable de l'auteur** : `ZMEMBERJID`. **Risque** : une même personne peut
apparaître sous un `@lid` et sous un `@s.whatsapp.net`. `LID.sqlite` permettrait
probablement de les rapprocher (non exploré).

**Mentions** : dans `ZTEXT`, une mention s'écrit `@` suivi d'un numéro (partie
utilisateur du LID ou du numéro de téléphone), pas d'un nom. La pseudonymisation devra
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

Environ 3 900 messages de groupe ont au moins une réaction. C'est un signal d'approbation
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
