#!/usr/bin/env python3
"""Diagnostic de la base locale WhatsApp Desktop (phase 0 de DistiX).

Lecture seule, bibliothèque standard uniquement (Python 3.9+).

Règles appliquées :
- les fichiers de WhatsApp ne sont jamais ouverts autrement qu'en lecture binaire,
  le temps d'en faire une copie dans data/tmp/ ;
- seule la copie est ouverte par SQLite, en mode lecture seule ;
- la copie est supprimée à la fin (sauf --keep-copy).

Commandes :
  report            rapport sans aucun contenu de message, partageable tel quel
  schema            tables et colonnes de la base
  groups            liste des groupes (noms, volumes, dates)  -> local uniquement
  messages GROUPE   30 derniers messages d'un groupe          -> local uniquement
  chat-props GROUPE colonnes non textuelles d'un groupe, pour comparer deux groupes

GROUPE est un morceau du nom (insensible à la casse) ou le JID complet (…@g.us).
"""
from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import hashlib
import re
import shutil
import sqlite3
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DB = (Path.home() / "Library" / "Group Containers"
              / "group.net.whatsapp.WhatsApp.shared" / "ChatStorage.sqlite")
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"

# Époque Core Data : 2001-01-01T00:00:00Z.
CORE_DATA_EPOCH = 978307200

# Colonnes sans lesquelles aucune lecture n'est possible.
REQUIRED = {
    "ZWACHATSESSION": ["Z_PK", "ZCONTACTJID", "ZPARTNERNAME"],
    "ZWAMESSAGE": ["Z_PK", "ZCHATSESSION", "ZTEXT", "ZMESSAGEDATE",
                   "ZISFROMME", "ZMESSAGETYPE"],
}
# Colonnes utiles mais dont l'absence ne bloque pas le diagnostic.
OPTIONAL = {
    "ZWACHATSESSION": ["ZSESSIONTYPE", "ZGROUPINFO", "ZLASTMESSAGEDATE",
                       "ZREMOVED", "ZHIDDEN", "ZARCHIVED"],
    "ZWAMESSAGE": ["ZSTANZAID", "ZFROMJID", "ZTOJID", "ZPUSHNAME", "ZGROUPMEMBER",
                   "ZGROUPEVENTTYPE", "ZMEDIAITEM", "ZPARENTMESSAGE", "ZFLAGS",
                   "ZSENTDATE", "ZMESSAGESTATUS", "ZSORT"],
    "ZWAGROUPMEMBER": ["Z_PK", "ZCHATSESSION", "ZMEMBERJID", "ZCONTACTNAME",
                       "ZFIRSTNAME"],
    "ZWAMEDIAITEM": ["Z_PK", "ZMESSAGE", "ZMETADATA", "ZTITLE", "ZMEDIALOCALPATH",
                     "ZFILESIZE"],
    "ZWAPROFILEPUSHNAME": ["ZJID", "ZPUSHNAME"],
    "ZWAMESSAGEINFO": ["ZMESSAGE", "ZRECEIPTINFO"],
}

# Correspondance ZMESSAGETYPE -> libellé. HYPOTHÈSE tirée de la littérature
# forensique sur WhatsApp iOS : à confirmer par le rapport, jamais à supposer.
TYPE_GUESS = {
    0: "texte", 1: "image", 2: "vidéo", 3: "audio", 4: "contact",
    5: "position", 6: "système", 7: "lien", 8: "document", 10: "appel ou notification (sans contenu)",
    11: "gif", 14: "supprimé", 15: "sticker",
}

GROUP_SUFFIX = "@g.us"


class DiagnoseError(Exception):
    """Erreur attendue, affichée sans trace d'exécution."""


# --------------------------------------------------------------------------
# Accès à la base : copie puis ouverture en lecture seule
# --------------------------------------------------------------------------

def _companions(db: Path) -> list[Path]:
    return [db, Path(str(db) + "-wal"), Path(str(db) + "-shm")]


def fingerprint(db: Path) -> dict[str, tuple[int, int]]:
    """Taille et date de modification des fichiers d'origine (sans les ouvrir)."""
    out = {}
    for p in _companions(db):
        with contextlib.suppress(FileNotFoundError):
            st = p.stat()
            out[p.name] = (st.st_size, st.st_mtime_ns)
    return out


def _copy_once(db: Path, dest_dir: Path) -> Path:
    for src in _companions(db):
        if not src.exists():
            continue
        # Ouverture binaire en lecture seule : aucune écriture possible sur la source.
        with open(src, "rb") as fsrc, open(dest_dir / src.name, "wb") as fdst:
            shutil.copyfileobj(fsrc, fdst, 1024 * 1024)
    return dest_dir / db.name


def open_copy(db: Path, keep: bool = False, attempts: int = 3):
    """Context manager : copie la base et renvoie une connexion en lecture seule.

    WhatsApp peut écrire pendant la copie. On vérifie l'intégrité de la copie
    et on recommence si elle est incohérente.
    """
    return _CopyContext(db, keep, attempts)


class _CopyContext:
    def __init__(self, db: Path, keep: bool, attempts: int):
        self.db, self.keep, self.attempts = db, keep, attempts
        self.dir: Path | None = None
        self.conn: sqlite3.Connection | None = None

    def __enter__(self) -> sqlite3.Connection:
        if not self.db.exists():
            raise DiagnoseError(
                f"Base introuvable : {self.db}\n"
                "WhatsApp Desktop est-il installé et connecté sur ce Mac ?")
        tmp_root = DATA_DIR / "tmp"
        tmp_root.mkdir(parents=True, exist_ok=True)
        last_error = ""
        for _ in range(self.attempts):
            self.dir = Path(tempfile.mkdtemp(prefix="wa-", dir=tmp_root))
            try:
                copy = _copy_once(self.db, self.dir)
            except PermissionError as e:
                self._cleanup()
                raise DiagnoseError(
                    f"Lecture refusée par macOS : {e}\n"
                    "Accorder l'accès dans Réglages Système > Confidentialité et "
                    "sécurité > Accès complet au disque (ou accepter la demande "
                    "« accéder aux données d'autres apps ») pour l'app qui lance "
                    "ce script (Terminal, iTerm, VS Code…), puis la relancer.")
            uri = f"file:{copy}?mode=ro"
            conn = sqlite3.connect(uri, uri=True)
            try:
                ok = conn.execute("PRAGMA quick_check").fetchone()[0]
            except sqlite3.DatabaseError as e:
                ok = str(e)
            if ok == "ok":
                self.conn = conn
                return conn
            last_error = ok
            conn.close()
            self._cleanup()
        raise DiagnoseError(f"Copie incohérente après {self.attempts} essais : {last_error}")

    def _cleanup(self):
        if self.dir and not self.keep:
            shutil.rmtree(self.dir, ignore_errors=True)

    def __exit__(self, *exc):
        if self.conn:
            self.conn.close()
        if self.keep and self.dir:
            print(f"(copie conservée dans {self.dir})", file=sys.stderr)
        self._cleanup()
        return False


# --------------------------------------------------------------------------
# Introspection
# --------------------------------------------------------------------------

def tables(conn) -> list[str]:
    return [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]


def columns(conn, table: str) -> list[tuple[str, str]]:
    return [(r[1], r[2]) for r in conn.execute(f'PRAGMA table_info("{table}")')]


def colset(conn, table: str) -> set[str]:
    return {c for c, _ in columns(conn, table)}


def validate_schema(conn) -> tuple[list[str], list[str]]:
    """Renvoie (manquants obligatoires, manquants optionnels), sous forme TABLE.COL."""
    present = set(tables(conn))
    def missing(spec):
        out = []
        for t, cols in spec.items():
            have = colset(conn, t) if t in present else set()
            out += [f"{t}.{c}" for c in cols if c not in have]
        return out
    return missing(REQUIRED), missing(OPTIONAL)


def require_schema(conn):
    req, _ = validate_schema(conn)
    if req:
        raise DiagnoseError(
            "Le schéma de la base WhatsApp a changé, colonnes absentes :\n  "
            + "\n  ".join(req)
            + "\nAucune lecture effectuée. Lancer `diagnose.py schema` et mettre à "
              "jour le connecteur.")


def has(conn, table: str, col: str) -> bool:
    return table in tables(conn) and col in colset(conn, table)


def to_datetime(value) -> datetime | None:
    """Date Core Data (secondes depuis 2001) -> datetime en heure locale."""
    if value is None:
        return None
    return datetime.fromtimestamp(float(value) + CORE_DATA_EPOCH, tz=timezone.utc).astimezone()


def fmt_dt(value) -> str:
    dt = to_datetime(value)
    return dt.strftime("%Y-%m-%d %H:%M") if dt else "—"


def entity_names(conn) -> dict[int, str]:
    if "Z_PRIMARYKEY" not in tables(conn):
        return {}
    return {r[0]: r[1] for r in conn.execute("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY")}


# --------------------------------------------------------------------------
# Groupes
# --------------------------------------------------------------------------

def list_groups(conn) -> list[dict]:
    """Toutes les conversations de groupe, avec volumes et dates (sans contenu)."""
    require_schema(conn)
    rows = conn.execute(
        """
        SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME,
               COUNT(m.Z_PK), MIN(m.ZMESSAGEDATE), MAX(m.ZMESSAGEDATE)
        FROM ZWACHATSESSION s
        LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
        WHERE s.ZCONTACTJID LIKE '%' || ?
        GROUP BY s.Z_PK
        ORDER BY MAX(m.ZMESSAGEDATE) DESC
        """, (GROUP_SUFFIX,)).fetchall()
    return [dict(pk=r[0], jid=r[1], name=r[2] or "(sans nom)", count=r[3],
                 first=r[4], last=r[5]) for r in rows]


def find_group(conn, query: str) -> dict:
    groups = list_groups(conn)
    exact = [g for g in groups if g["jid"] == query]
    if exact:
        return exact[0]
    q = query.casefold()
    hits = [g for g in groups if q in g["name"].casefold()]
    if not hits:
        raise DiagnoseError(f"Aucun groupe ne correspond à « {query} ». Voir `groups`.")
    if len(hits) > 1:
        names = "\n  ".join(f"{g['name']}  ({g['jid']})" for g in hits)
        raise DiagnoseError(f"Plusieurs groupes correspondent, préciser :\n  {names}")
    return hits[0]


# --------------------------------------------------------------------------
# Messages
# --------------------------------------------------------------------------

def _author_resolver(conn, chat_pk: int):
    """Construit une fonction -> (jid, nom, source du nom), selon les colonnes présentes.

    Constaté (rapport 2026-10-07) : dans un groupe, ZFROMJID vaut le JID du groupe ;
    l'auteur est ZGROUPMEMBER -> ZWAGROUPMEMBER.ZMEMBERJID (surtout des @lid).
    ZCONTACTNAME est toujours une chaîne vide ; le nom vient surtout de
    ZWAPROFILEPUSHNAME (84 % des messages reçus).
    """
    members: dict[int, tuple[str | None, str | None, str | None]] = {}
    if has(conn, "ZWAGROUPMEMBER", "ZMEMBERJID"):
        cs = colset(conn, "ZWAGROUPMEMBER")
        name_cols = [c for c in ("ZCONTACTNAME", "ZFIRSTNAME") if c in cs]
        sel = ", ".join(["Z_PK", "ZMEMBERJID"] + name_cols)
        where = " WHERE ZCHATSESSION = ?" if "ZCHATSESSION" in cs else ""
        args = (chat_pk,) if where else ()
        for r in conn.execute(f"SELECT {sel} FROM ZWAGROUPMEMBER{where}", args):
            named = [(c, v.strip()) for c, v in zip(name_cols, r[2:]) if v and v.strip()]
            members[r[0]] = (r[1],) + (named[0] if named else (None, None))
    push: dict[str, str] = {}
    if has(conn, "ZWAPROFILEPUSHNAME", "ZPUSHNAME") and has(conn, "ZWAPROFILEPUSHNAME", "ZJID"):
        push = {j: n.strip() for j, n in conn.execute(
            "SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") if n and n.strip()}

    def resolve(is_from_me, group_member, from_jid, raw_pushname) -> tuple[str, str, str]:
        if is_from_me:
            return "moi", "moi", "moi"
        jid, col, name = members.get(group_member, (None, None, None)) if group_member else (None, None, None)
        if not jid and from_jid and not from_jid.endswith(GROUP_SUFFIX):
            jid = from_jid
        if name:
            return jid or "?", name, f"ZWAGROUPMEMBER.{col}"
        if jid and push.get(jid):
            return jid, push[jid], "ZWAPROFILEPUSHNAME"
        # ZWAMESSAGE.ZPUSHNAME n'est pas utilisé : constaté le 2026-10-07, c'est un
        # protobuf d'entiers (métadonnées), pas un nom. Voir docs/schema-whatsapp.md.
        return jid or "?", jid or "?", "aucun"
    return resolve


B64_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")


def pushname_layers(v) -> tuple[str, list[tuple[str, str, object]]]:
    """Décode ZWAMESSAGE.ZPUSHNAME : (format, feuilles protobuf éventuelles)."""
    if v is None:
        return "nul", []
    raw = v
    fmt = "blob"
    if isinstance(v, str):
        if not (B64_RE.match(v) and len(v) % 4 == 0):
            return "texte", []
        try:
            raw = base64.b64decode(v, validate=True)
        except (ValueError, binascii.Error):
            return "texte", []
        fmt = "base64"
    try:
        pb_parse(bytes(raw))
    except ValueError:
        return fmt + "+opaque", []
    return fmt + "+protobuf", list(pb_leaves(bytes(raw)))


def recent_messages(conn, chat_pk: int, limit: int = 30) -> list[dict]:
    require_schema(conn)
    cols = colset(conn, "ZWAMESSAGE")
    opt = [c for c in ("ZSTANZAID", "ZFROMJID", "ZPUSHNAME", "ZGROUPMEMBER",
                       "ZGROUPEVENTTYPE", "ZMEDIAITEM", "ZPARENTMESSAGE") if c in cols]
    sel = ", ".join(["Z_PK", "ZMESSAGEDATE", "ZISFROMME", "ZMESSAGETYPE", "ZTEXT"] + opt)
    rows = conn.execute(
        f"SELECT {sel} FROM ZWAMESSAGE WHERE ZCHATSESSION = ? "
        f"ORDER BY ZMESSAGEDATE DESC, Z_PK DESC LIMIT ?", (chat_pk, limit)).fetchall()
    rows.reverse()
    names = ["pk", "date", "from_me", "type", "text"] + [c[1:].lower() for c in opt]
    resolve = _author_resolver(conn, chat_pk)

    reply_ids = quoted_stanza_ids(conn, chat_pk, [r[0] for r in rows])
    reacts = reactions(conn, [r[0] for r in rows])
    out = []
    for r in rows:
        d = dict(zip(names, r))
        jid, author, source = resolve(d["from_me"], d.get("groupmember"), d.get("fromjid"),
                                      d.get("pushname"))
        d["author_jid"], d["author"], d["author_source"] = jid, author, source
        d["reply_to"] = reply_ids.get(d["pk"])
        d["reactions"] = reacts.get(d["pk"], Counter())
        out.append(d)
    return out


# Constaté (rapport 2026-10-07) : dans ZWAMEDIAITEM.ZMETADATA, le champ 5 contient
# l'identifiant (stanza) du message cité et le champ 6 le JID de son auteur.
REPLY_ID_PATH, REPLY_AUTHOR_PATH = "5", "6"
# Dans ZWAMESSAGEINFO.ZRECEIPTINFO, le champ 7 regroupe les réactions
# (7.1.2 : JID de l'auteur, 7.1.3 : emoji).
REACTIONS_FIELD = "7"


def quoted_stanza_ids(conn, chat_pk: int, message_pks: list[int]) -> dict[int, str]:
    """Message -> identifiant (stanza) du message cité, d'après ZMETADATA champ 5."""
    if not message_pks or not (has(conn, "ZWAMEDIAITEM", "ZMETADATA")
                               and has(conn, "ZWAMEDIAITEM", "ZMESSAGE")):
        return {}
    marks = ",".join("?" * len(message_pks))
    out = {}
    for msg, blob in conn.execute(
            f"SELECT ZMESSAGE, ZMETADATA FROM ZWAMEDIAITEM "
            f"WHERE ZMESSAGE IN ({marks}) AND ZMETADATA IS NOT NULL", message_pks):
        for path, s in pb_strings(blob):
            if path == REPLY_ID_PATH:
                out[msg] = s
                break
    return out


def reactions(conn, message_pks: list[int]) -> dict[int, Counter]:
    """Message -> compteur d'emoji de réaction, d'après ZRECEIPTINFO champ 7."""
    if not message_pks or not (has(conn, "ZWAMESSAGEINFO", "ZRECEIPTINFO")
                               and has(conn, "ZWAMESSAGEINFO", "ZMESSAGE")):
        return {}
    marks = ",".join("?" * len(message_pks))
    out: dict[int, Counter] = {}
    for msg, blob in conn.execute(
            f"SELECT ZMESSAGE, ZRECEIPTINFO FROM ZWAMESSAGEINFO "
            f"WHERE ZMESSAGE IN ({marks}) AND ZRECEIPTINFO IS NOT NULL", message_pks):
        c = Counter(v for path, v in pb_strings(blob)
                    if path.split(".")[0] == REACTIONS_FIELD and looks_emoji(v))
        if c:
            out[msg] = c
    return out


# --------------------------------------------------------------------------
# Décodage protobuf minimal (structure seulement, pour localiser des champs)
# --------------------------------------------------------------------------

def _varint(buf: bytes, i: int) -> tuple[int, int]:
    shift = result = 0
    while True:
        if i >= len(buf) or shift > 63:
            raise ValueError("varint")
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def pb_parse(buf: bytes) -> list[tuple[int, int, object]]:
    """Analyse un message protobuf. Lève ValueError si ce n'en est pas un."""
    fields, i = [], 0
    while i < len(buf):
        key, i = _varint(buf, i)
        field, wire = key >> 3, key & 7
        if field == 0:
            raise ValueError("champ 0")
        if wire == 0:
            val, i = _varint(buf, i)
        elif wire == 1:
            val, i = buf[i:i + 8], i + 8
        elif wire == 2:
            n, i = _varint(buf, i)
            if i + n > len(buf):
                raise ValueError("longueur")
            val, i = buf[i:i + n], i + n
        elif wire == 5:
            val, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f"wiretype {wire}")
        if i > len(buf):
            raise ValueError("tronqué")
        fields.append((field, wire, val))
    return fields


def _printable(b: bytes) -> str | None:
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if s and all(c.isprintable() or c in "\n\t" for c in s):
        return s
    return None


def pb_leaves(buf: bytes, path: str = "", depth: int = 0):
    """Feuilles (chemin, type, valeur) ; les sous-messages sont parcourus."""
    try:
        fields = pb_parse(buf)
    except ValueError:
        return
    for field, wire, val in fields:
        p = f"{path}.{field}" if path else str(field)
        if wire == 2:
            s = _printable(val)
            sub = None
            if depth < 6 and val:
                try:
                    pb_parse(val)
                    sub = True
                except ValueError:
                    sub = None
            # Une chaîne lisible peut aussi se parser comme protobuf : on privilégie
            # la chaîne si elle est lisible.
            if s is not None:
                yield p, "str", s
            elif sub:
                yield from pb_leaves(val, p, depth + 1)
            else:
                yield p, "bytes", val
        elif wire == 0:
            yield p, "int", val
        else:
            yield p, "fixed", val


def pb_strings(buf: bytes):
    if not isinstance(buf, (bytes, bytearray)):
        return []
    return [(p, v) for p, kind, v in pb_leaves(bytes(buf)) if kind == "str"]


JID_RE = re.compile(r"^[\w.-]+@(s\.whatsapp\.net|lid|g\.us|broadcast)$")
URL_RE = re.compile(r"^https?://")


def looks_emoji(s: str) -> bool:
    return 0 < len(s) <= 8 and all(ord(c) >= 0x2000 or c in "‍️" for c in s)


def classify_string(s: str, stanzas: set[str]) -> str:
    """Catégorie d'une chaîne, sans jamais renvoyer son contenu."""
    if s in stanzas:
        return "id_message_connu"
    if JID_RE.match(s):
        return "jid:" + s.split("@", 1)[1]
    if URL_RE.match(s):
        return "url"
    if looks_emoji(s):
        return "emoji"
    return "texte"


# --------------------------------------------------------------------------
# Rapport (aucun contenu de message, partageable)
# --------------------------------------------------------------------------

def _pct(a: int, b: int) -> str:
    return f"{100 * a / b:.0f} %" if b else "—"


def _anon(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:8]


def section_schema(conn, out: list[str]):
    out.append("## Tables et colonnes\n")
    ents = entity_names(conn)
    if ents:
        out.append("Entités Core Data (Z_PRIMARYKEY) : "
                   + ", ".join(f"{k}={v}" for k, v in sorted(ents.items())) + "\n")
    for t in tables(conn):
        n = conn.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        cols = columns(conn, t)
        out.append(f"### {t} ({n} lignes)\n")
        if n and t.startswith("Z") and n < 5_000_000:
            parts = ", ".join(f'COUNT("{c}")' for c, _ in cols)
            nn = conn.execute(f'SELECT {parts} FROM "{t}"').fetchone()
        else:
            nn = [None] * len(cols)
        out.append("| colonne | type | non nuls |\n|---|---|---|")
        for (c, ty), k in zip(cols, nn):
            out.append(f"| {c} | {ty or '?'} | {'' if k is None else k} |")
        out.append("")
    req, opt = validate_schema(conn)
    out.append("### Validation\n")
    out.append("- Colonnes obligatoires manquantes : " + (", ".join(req) or "aucune"))
    out.append("- Colonnes optionnelles manquantes : " + (", ".join(opt) or "aucune") + "\n")


def _group_pks(conn) -> list[int]:
    return [r[0] for r in conn.execute(
        "SELECT Z_PK FROM ZWACHATSESSION WHERE ZCONTACTJID LIKE '%' || ?", (GROUP_SUFFIX,))]


def section_sessions(conn, out: list[str]):
    out.append("## Conversations\n")
    if has(conn, "ZWACHATSESSION", "ZSESSIONTYPE"):
        out.append("| ZSESSIONTYPE | suffixe du JID | nombre |\n|---|---|---|")
        rows = conn.execute("SELECT ZSESSIONTYPE, ZCONTACTJID FROM ZWACHATSESSION").fetchall()
        c = Counter((t, (j or "").rsplit("@", 1)[-1] if j and "@" in j else "(aucun)")
                    for t, j in rows)
        for (t, suf), n in sorted(c.items(), key=lambda x: (str(x[0][0]), x[0][1])):
            out.append(f"| {t} | {suf} | {n} |")
        out.append("")
    groups = list_groups(conn)
    out.append(f"Groupes (JID en `{GROUP_SUFFIX}`) : {len(groups)}, "
               f"dont {sum(1 for g in groups if g['count'])} avec des messages.\n")
    out.append("Volumes par groupe (noms masqués, identifiant = hachage du JID) :\n")
    out.append("| groupe | messages | premier | dernier |\n|---|---|---|---|")
    for g in groups[:40]:
        out.append(f"| {_anon(g['jid'])} | {g['count']} | {fmt_dt(g['first'])} | {fmt_dt(g['last'])} |")
    out.append("")


def section_history(conn, out: list[str]):
    out.append("## Profondeur d'historique (tous groupes confondus)\n")
    pks = _group_pks(conn)
    if not pks:
        out.append("Aucun groupe.\n")
        return
    marks = ",".join("?" * len(pks))
    rows = conn.execute(
        f"SELECT ZMESSAGEDATE FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
        f"AND ZMESSAGEDATE IS NOT NULL", pks).fetchall()
    months = Counter(to_datetime(r[0]).strftime("%Y-%m") for r in rows)
    out.append("| mois | messages |\n|---|---|")
    for m in sorted(months):
        out.append(f"| {m} | {months[m]} |")
    out.append("")
    raw = conn.execute(
        f"SELECT MIN(ZMESSAGEDATE), MAX(ZMESSAGEDATE) FROM ZWAMESSAGE "
        f"WHERE ZCHATSESSION IN ({marks})", pks).fetchone()
    out.append(f"Valeurs brutes de ZMESSAGEDATE : min={raw[0]}, max={raw[1]} "
               f"(interprétées comme secondes depuis 2001-01-01 : "
               f"{fmt_dt(raw[0])} → {fmt_dt(raw[1])}, heure locale).\n")


def section_types(conn, out: list[str]):
    out.append("## Types de messages (groupes uniquement)\n")
    pks = _group_pks(conn)
    if not pks:
        return
    marks = ",".join("?" * len(pks))
    cols = colset(conn, "ZWAMESSAGE")
    extra = [c for c in ("ZGROUPEVENTTYPE", "ZMEDIAITEM", "ZPARENTMESSAGE", "ZFLAGS") if c in cols]
    sel = ", ".join(["ZMESSAGETYPE", "COUNT(*)", "COUNT(ZTEXT)"]
                    + [f"COUNT({c})" for c in extra])
    rows = conn.execute(
        f"SELECT {sel} FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
        f"GROUP BY ZMESSAGETYPE ORDER BY COUNT(*) DESC", pks).fetchall()
    head = ["ZMESSAGETYPE", "libellé supposé", "messages", "avec ZTEXT"] + [f"avec {c}" for c in extra]
    out.append("| " + " | ".join(head) + " |\n|" + "---|" * len(head))
    for r in rows:
        t, n = r[0], r[1]
        cells = [str(t), TYPE_GUESS.get(t, "?"), str(n)] + [_pct(k, n) for k in r[2:]]
        out.append("| " + " | ".join(cells) + " |")
    out.append("")
    if "ZGROUPEVENTTYPE" in cols:
        rows = conn.execute(
            f"SELECT ZMESSAGETYPE, ZGROUPEVENTTYPE, COUNT(*) FROM ZWAMESSAGE "
            f"WHERE ZCHATSESSION IN ({marks}) AND ZGROUPEVENTTYPE IS NOT NULL "
            f"AND ZGROUPEVENTTYPE != 0 GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 30", pks).fetchall()
        if rows:
            out.append("Événements de groupe (ZMESSAGETYPE, ZGROUPEVENTTYPE, nombre) : "
                       + ", ".join(f"({a}, {b}, {c})" for a, b, c in rows) + "\n")
    if "ZFLAGS" in cols:
        rows = conn.execute(
            f"SELECT ZFLAGS, COUNT(*) FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
            f"GROUP BY 1 ORDER BY 2 DESC LIMIT 15", pks).fetchall()
        out.append("Valeurs de ZFLAGS (valeur, nombre) : "
                   + ", ".join(f"({a}, {b})" for a, b in rows) + "\n")


def section_authors(conn, out: list[str]):
    out.append("## Identité des auteurs (groupes uniquement)\n")
    pks = _group_pks(conn)
    if not pks:
        return
    marks = ",".join("?" * len(pks))
    cols = colset(conn, "ZWAMESSAGE")
    base = f"FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) AND ZISFROMME = 0"
    total = conn.execute(f"SELECT COUNT(*) {base}", pks).fetchone()[0]
    out.append(f"Messages reçus : {total}")
    for c in ("ZGROUPMEMBER", "ZFROMJID", "ZPUSHNAME"):
        if c in cols:
            n = conn.execute(f"SELECT COUNT({c}) {base}", pks).fetchone()[0]
            out.append(f"- avec {c} : {_pct(n, total)}")
    if "ZFROMJID" in cols:
        c = Counter((j or "").rsplit("@", 1)[-1] for (j,) in
                    conn.execute(f"SELECT ZFROMJID {base}", pks))
        out.append("- suffixes de ZFROMJID : " + ", ".join(f"{k or '(vide)'}={v}" for k, v in c.most_common()))
    if has(conn, "ZWAGROUPMEMBER", "ZMEMBERJID"):
        c = Counter((j or "").rsplit("@", 1)[-1] for (j,) in
                    conn.execute("SELECT ZMEMBERJID FROM ZWAGROUPMEMBER"))
        out.append("- suffixes de ZWAGROUPMEMBER.ZMEMBERJID : "
                   + ", ".join(f"{k or '(vide)'}={v}" for k, v in c.most_common()))
    if "ZPUSHNAME" in cols:
        ty = conn.execute(f"SELECT typeof(ZPUSHNAME), COUNT(*) {base} GROUP BY 1", pks).fetchall()
        out.append("- type SQLite de ZPUSHNAME : " + ", ".join(f"{a}={b}" for a, b in ty))
    out.append("")


def section_names(conn, out: list[str]):
    out.append("## Noms des auteurs (groupes uniquement)\n")
    pks = _group_pks(conn)
    if not pks:
        return
    if has(conn, "ZWAGROUPMEMBER", "ZCONTACTNAME"):
        empty, filled = conn.execute(
            "SELECT SUM(TRIM(ZCONTACTNAME) = ''), SUM(TRIM(ZCONTACTNAME) != '') FROM ZWAGROUPMEMBER"
        ).fetchone()
        out.append(f"- ZWAGROUPMEMBER.ZCONTACTNAME : {filled or 0} renseignés, {empty or 0} chaînes vides")
    if has(conn, "ZWAGROUPMEMBER", "ZFIRSTNAME"):
        n = conn.execute("SELECT COUNT(*) FROM ZWAGROUPMEMBER WHERE TRIM(ZFIRSTNAME) != ''").fetchone()[0]
        out.append(f"- ZWAGROUPMEMBER.ZFIRSTNAME renseignés : {n}")
    if has(conn, "ZWAPROFILEPUSHNAME", "ZJID") and has(conn, "ZWAGROUPMEMBER", "ZMEMBERJID"):
        n, k = conn.execute(
            "SELECT COUNT(DISTINCT g.ZMEMBERJID), COUNT(DISTINCT p.ZJID) FROM ZWAGROUPMEMBER g "
            "LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = g.ZMEMBERJID").fetchone()
        out.append(f"- membres distincts : {n}, dont {k} ({_pct(k, n)}) ont un nom dans ZWAPROFILEPUSHNAME")
    out.append("")
    cols = colset(conn, "ZWAMESSAGE")
    marks = ",".join("?" * len(pks))
    if "ZPUSHNAME" in cols:
        rows = conn.execute(
            f"SELECT ZPUSHNAME FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) AND ZISFROMME = 0 "
            f"AND ZPUSHNAME IS NOT NULL LIMIT 20000", pks).fetchall()
        fmts, paths = Counter(), defaultdict(Counter)
        lengths = Counter()
        for (v,) in rows:
            fmt, leaves = pushname_layers(v)
            fmts[fmt] += 1
            lengths[len(v) if isinstance(v, (str, bytes)) else 0] += 1
            seen = set()
            for path, kind, x in leaves:
                cat = classify_string(x, set()) if kind == "str" else kind
                if (path, cat) not in seen:
                    paths[path][cat] += 1
                    seen.add((path, cat))
        out.append("ZWAMESSAGE.ZPUSHNAME, format : " + ", ".join(f"{k} = {v}" for k, v in fmts.most_common()))
        out.append("- longueurs les plus fréquentes : " + ", ".join(f"{k} car. = {v}" for k, v in lengths.most_common(5)))
        if paths:
            out.append("- structure décodée : " + "; ".join(
                f"{p} → " + ", ".join(f"{k} : {v}" for k, v in paths[p].most_common())
                for p in sorted(paths)))
        out.append("")
    # Couverture de la résolution des noms, sur un échantillon de messages reçus.
    sources = Counter()
    for (chat,) in conn.execute(
            f"SELECT ZCHATSESSION FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
            f"GROUP BY ZCHATSESSION ORDER BY COUNT(*) DESC LIMIT 5", pks).fetchall():
        resolve = _author_resolver(conn, chat)
        sel = ", ".join(c if c in cols else "NULL" for c in ("ZGROUPMEMBER", "ZFROMJID", "ZPUSHNAME"))
        for gm, fj, pn in conn.execute(
                f"SELECT {sel} FROM ZWAMESSAGE WHERE ZCHATSESSION = ? AND ZISFROMME = 0 "
                f"ORDER BY ZMESSAGEDATE DESC LIMIT 2000", (chat,)):
            sources[resolve(0, gm, fj, pn)[2]] += 1
    total = sum(sources.values())
    out.append("Résolution des noms (5 groupes les plus actifs, 2000 derniers messages reçus chacun) : "
               + ", ".join(f"{k} = {v} ({_pct(v, total)})" for k, v in sources.most_common()) + "\n")
    mentions = conn.execute(
        f"SELECT COUNT(*) FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
        f"AND ZTEXT GLOB '*@[0-9][0-9][0-9][0-9][0-9][0-9]*'", pks).fetchone()[0]
    out.append(f"Messages contenant une mention « @<numéro> » : {mentions}\n")


def section_reaction_counts(conn, out: list[str]):
    pks = _group_pks(conn)
    if not pks or not has(conn, "ZWAMESSAGEINFO", "ZRECEIPTINFO"):
        return
    marks = ",".join("?" * len(pks))
    msg_pks = [r[0] for r in conn.execute(
        f"SELECT Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) AND ZMESSAGEINFO IS NOT NULL"
        if "ZMESSAGEINFO" in colset(conn, "ZWAMESSAGE") else
        f"SELECT Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks})", pks)]
    found: dict[int, Counter] = {}
    for i in range(0, len(msg_pks), 900):
        found.update(reactions(conn, msg_pks[i:i + 900]))
    n_react = sum(sum(c.values()) for c in found.values())
    out.append(f"Réactions lues via le champ {REACTIONS_FIELD} : {len(found)} messages de groupe "
               f"ont au moins une réaction, {n_react} réactions au total.\n")


def _blob_structure(rows, stanzas: set[str], title: str, out: list[str]):
    """Histogramme des chemins protobuf par catégorie de valeur (sans contenu)."""
    paths: dict[str, Counter] = defaultdict(Counter)
    parsed = notpb = 0
    for (blob,) in rows:
        if not isinstance(blob, (bytes, bytearray)):
            continue
        try:
            pb_parse(bytes(blob))
        except ValueError:
            notpb += 1
            continue
        parsed += 1
        seen = set()
        for p, kind, v in pb_leaves(bytes(blob)):
            cat = classify_string(v, stanzas) if kind == "str" else kind
            if (p, cat) not in seen:
                paths[p][cat] += 1
                seen.add((p, cat))
    out.append(f"{title} : {parsed} blobs lisibles comme protobuf, {notpb} non lisibles.\n")
    if not paths:
        return
    out.append("| chemin | catégorie : nombre de blobs |\n|---|---|")
    for p in sorted(paths, key=lambda x: -sum(paths[x].values()))[:40]:
        out.append(f"| {p} | " + ", ".join(f"{k} : {v}" for k, v in paths[p].most_common()) + " |")
    out.append("")


def section_replies(conn, out: list[str]):
    out.append("## Lien « réponse à »\n")
    pks = _group_pks(conn)
    if not pks:
        return
    marks = ",".join("?" * len(pks))
    cols = colset(conn, "ZWAMESSAGE")
    for c in sorted(cols):
        if re.search(r"PARENT|QUOT|REPLY|CONTEXT|ORIGIN", c):
            n = conn.execute(f"SELECT COUNT({c}) FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks})",
                             pks).fetchone()[0]
            out.append(f"- colonne candidate ZWAMESSAGE.{c} : {n} valeurs non nulles")
    if not (has(conn, "ZWAMEDIAITEM", "ZMETADATA") and has(conn, "ZWAMEDIAITEM", "ZMESSAGE")
            and "ZSTANZAID" in cols):
        out.append("- ZWAMEDIAITEM.ZMETADATA ou ZWAMESSAGE.ZSTANZAID absent : analyse impossible.\n")
        return
    stanzas = {r[0] for r in conn.execute(
        f"SELECT ZSTANZAID FROM ZWAMESSAGE WHERE ZCHATSESSION IN ({marks}) "
        f"AND ZSTANZAID IS NOT NULL", pks)}
    rows = conn.execute(
        f"""SELECT m.ZMESSAGETYPE, mi.ZMETADATA FROM ZWAMEDIAITEM mi
            JOIN ZWAMESSAGE m ON m.Z_PK = mi.ZMESSAGE
            WHERE m.ZCHATSESSION IN ({marks}) AND mi.ZMETADATA IS NOT NULL""", pks).fetchall()
    by_type = Counter()
    hit_type = Counter()
    for t, blob in rows:
        by_type[t] += 1
        if any(s in stanzas for _, s in pb_strings(blob)):
            hit_type[t] += 1
    out.append(f"- ZMETADATA non nul pour {len(rows)} messages de groupe.")
    out.append("- Contenant l'identifiant d'un autre message de la base, par ZMESSAGETYPE : "
               + ", ".join(f"type {t} : {hit_type[t]}/{by_type[t]}" for t in sorted(by_type, key=str)))
    out.append("")
    _blob_structure([(b,) for _, b in rows[:20000]], stanzas,
                    "Structure de ZWAMEDIAITEM.ZMETADATA", out)


def section_reactions(conn, out: list[str]):
    out.append("## Réactions\n")
    cand = [t for t in tables(conn) if re.search(r"REACT|RECEIPT|MESSAGEINFO|ADDON", t)]
    out.append("- Tables candidates : " + (", ".join(cand) or "aucune"))
    for t in cand:
        out.append(f"  - {t} : " + ", ".join(c for c, _ in columns(conn, t)))
    out.append("")
    if has(conn, "ZWAMESSAGEINFO", "ZRECEIPTINFO") and has(conn, "ZWAMESSAGEINFO", "ZMESSAGE"):
        pks = _group_pks(conn)
        marks = ",".join("?" * len(pks)) or "NULL"
        rows = conn.execute(
            f"""SELECT i.ZRECEIPTINFO FROM ZWAMESSAGEINFO i
                JOIN ZWAMESSAGE m ON m.Z_PK = i.ZMESSAGE
                WHERE m.ZCHATSESSION IN ({marks}) AND i.ZRECEIPTINFO IS NOT NULL
                LIMIT 20000""", pks).fetchall()
        _blob_structure(rows, set(), "Structure de ZWAMESSAGEINFO.ZRECEIPTINFO", out)
    for t in cand:
        if t == "ZWAMESSAGEINFO":
            continue
        for c, ty in columns(conn, t):
            if (ty or "").upper() == "BLOB":
                rows = conn.execute(f'SELECT "{c}" FROM "{t}" WHERE "{c}" IS NOT NULL LIMIT 5000').fetchall()
                _blob_structure(rows, set(), f"Structure de {t}.{c}", out)


def section_group_settings(conn, out: list[str]):
    out.append("## Réglages de groupe (piste pour le blocage d'export)\n")
    for t in ("ZWAGROUPINFO", "ZWACHATSESSION", "ZWACHATPROPERTIES"):
        if t not in tables(conn):
            continue
        cs = columns(conn, t)
        cand = [c for c, ty in cs if re.search(
            r"RESTRICT|EXPORT|ANNOUNCE|LOCK|PRIVA|SETTING|ADMIN|EPHEMERAL|DISAPPEAR|FLAG|PROPERT|MODE",
            c)]
        out.append(f"- {t} : colonnes candidates : " + (", ".join(cand) or "aucune"))
        for c in cand:
            ty = dict(cs)[c]
            if (ty or "").upper() in ("INTEGER", "BOOLEAN", ""):
                dist = conn.execute(
                    f'SELECT "{c}", COUNT(*) FROM "{t}" GROUP BY 1 ORDER BY 2 DESC LIMIT 8').fetchall()
                out.append(f"  - {c} : " + ", ".join(f"{a}={b}" for a, b in dist))
    out.append("\nPour trancher : lancer `chat-props` sur un groupe où l'export est bloqué "
               "et sur un groupe où il ne l'est pas, puis comparer.\n")


def build_report(conn, db: Path) -> str:
    out = [f"# Rapport de diagnostic WhatsApp — {datetime.now().astimezone():%Y-%m-%d %H:%M %Z}\n",
           "Aucun contenu de message ni nom de groupe dans ce rapport.\n",
           f"- Base : `{db.name}`, SQLite {sqlite3.sqlite_version}, Python {sys.version.split()[0]}",
           f"- Fuseau local : {datetime.now().astimezone().tzname()}\n"]
    section_schema(conn, out)
    req, _ = validate_schema(conn)
    if req:
        out.append("**Schéma incompatible : sections suivantes non calculées.**\n")
        return "\n".join(out)
    for section in (section_sessions, section_history, section_types, section_authors,
                    section_names, section_replies, section_reactions, section_reaction_counts,
                    section_group_settings):
        try:
            section(conn, out)
        except sqlite3.Error as e:
            out.append(f"_Section {section.__name__} en échec : {type(e).__name__} {e}_\n")
    return "\n".join(out)


# --------------------------------------------------------------------------
# Commandes
# --------------------------------------------------------------------------

def cmd_report(conn, args) -> str:
    text = build_report(conn, args.db)
    dest = DATA_DIR / "reports"
    dest.mkdir(parents=True, exist_ok=True)
    path = dest / f"report-{datetime.now():%Y%m%d-%H%M%S}.md"
    path.write_text(text, encoding="utf-8")
    return text + f"\n\n(rapport enregistré dans {path})"


def cmd_schema(conn, args) -> str:
    out: list[str] = []
    section_schema(conn, out)
    return "\n".join(out)


def cmd_groups(conn, args) -> str:
    groups = list_groups(conn)
    lines = [f"{'messages':>9}  {'premier':16}  {'dernier':16}  nom  [jid]"]
    for g in groups:
        lines.append(f"{g['count']:>9}  {fmt_dt(g['first']):16}  {fmt_dt(g['last']):16}  "
                     f"{g['name']}  [{g['jid']}]")
    lines.append(f"\n{len(groups)} groupes.")
    return "\n".join(lines)


def cmd_messages(conn, args) -> str:
    g = find_group(conn, args.group)
    msgs = recent_messages(conn, g["pk"], args.limit)
    by_stanza = {m.get("stanzaid"): m for m in msgs if m.get("stanzaid")}
    lines = [f"{g['name']}  [{g['jid']}]  — {g['count']} messages, {len(msgs)} affichés\n"]
    for m in msgs:
        t = m["type"]
        kind = f"type {t} ({TYPE_GUESS.get(t, '?')})"
        text = (m["text"] or "").replace("\n", " ⏎ ")
        lines.append(f"{fmt_dt(m['date'])}  {m['author']}  · {kind}  · nom : {m['author_source']}")
        if m["reply_to"]:
            target = by_stanza.get(m["reply_to"])
            where = f"{fmt_dt(target['date'])} {target['author']}" if target else "hors fenêtre"
            lines.append(f"    ↳ en réponse à {m['reply_to']} ({where})")
        if text:
            lines.append(f"    {text}")
        if m["reactions"]:
            lines.append("    réactions : " + " ".join(f"{e}×{n}" for e, n in m["reactions"].most_common()))
    sources = Counter(m["author_source"] for m in msgs)
    lines.append("\nOrigine des noms : " + ", ".join(f"{k} = {v}" for k, v in sources.most_common()))
    return "\n".join(lines)


def cmd_chat_props(conn, args) -> str:
    g = find_group(conn, args.group)
    lines = [f"{g['name']}  [{g['jid']}]\n"]
    def dump(table, where, val):
        if table not in tables(conn):
            return
        cs = [(c, ty) for c, ty in columns(conn, table)
              if (ty or "").upper() not in ("VARCHAR", "TEXT", "BLOB")]
        row = conn.execute(f'SELECT {", ".join(chr(34) + c + chr(34) for c, _ in cs)} '
                           f'FROM "{table}" WHERE {where} = ?', (val,)).fetchone()
        if row:
            lines.append(f"## {table}")
            lines.extend(f"  {c} = {v}" for (c, _), v in zip(cs, row))
    dump("ZWACHATSESSION", "Z_PK", g["pk"])
    if has(conn, "ZWACHATSESSION", "ZGROUPINFO"):
        gi = conn.execute("SELECT ZGROUPINFO FROM ZWACHATSESSION WHERE Z_PK = ?",
                          (g["pk"],)).fetchone()[0]
        if gi is not None:
            dump("ZWAGROUPINFO", "Z_PK", gi)
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help="chemin de ChatStorage.sqlite")
    ap.add_argument("--keep-copy", action="store_true", help="ne pas supprimer la copie")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("report")
    sub.add_parser("schema")
    sub.add_parser("groups")
    p = sub.add_parser("messages")
    p.add_argument("group")
    p.add_argument("--limit", type=int, default=30)
    p = sub.add_parser("chat-props")
    p.add_argument("group")
    args = ap.parse_args(argv)

    handlers = {"report": cmd_report, "schema": cmd_schema, "groups": cmd_groups,
                "messages": cmd_messages, "chat-props": cmd_chat_props}
    before = fingerprint(args.db)
    try:
        with open_copy(args.db, keep=args.keep_copy) as conn:
            print(handlers[args.cmd](conn, args))
    except DiagnoseError as e:
        print(f"Erreur : {e}", file=sys.stderr)
        return 2
    after = fingerprint(args.db)
    if before != after:
        # Le script n'ouvre les originaux qu'en lecture binaire ; un changement ici
        # vient de WhatsApp lui-même, qui écrit en continu quand il est ouvert.
        changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
        print(f"\n(info : modifiés par WhatsApp pendant l'exécution : {', '.join(changed)})",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
