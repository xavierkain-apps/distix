"""Base factice au format de ChatStorage.sqlite, pour les tests.

Reproduit les particularités constatées sur la vraie base (docs/schema-whatsapp.md) :
ZFROMJID = JID du groupe pour les messages reçus, auteur via ZGROUPMEMBER,
ZCONTACTNAME souvent vide, ZPUSHNAME en base64, lien de réponse dans le champ 5
de ZMETADATA, réactions dans le champ 7 de ZRECEIPTINFO. Aucune donnée réelle.
"""
from __future__ import annotations

import base64
import sqlite3
from pathlib import Path

CORE_DATA_EPOCH = 978307200


def pb_varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_field(field: int, value) -> bytes:
    if isinstance(value, int):
        return pb_varint(field << 3) + pb_varint(value)
    if isinstance(value, str):
        value = value.encode()
    return pb_varint(field << 3 | 2) + pb_varint(len(value)) + value


def core_date(unix_ts: float) -> float:
    return unix_ts - CORE_DATA_EPOCH


SCHEMA = """
CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZSESSIONTYPE INTEGER,
  ZGROUPINFO INTEGER, ZLASTMESSAGEDATE TIMESTAMP, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR);
CREATE TABLE ZWAGROUPINFO (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZRESTRICTMODE INTEGER,
  ZANNOUNCEMENTONLY INTEGER, ZSUBJECTOWNERJID VARCHAR);
CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR,
  ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER,
  ZMEDIAITEM INTEGER, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZGROUPEVENTTYPE INTEGER,
  ZFLAGS INTEGER, ZMESSAGEDATE TIMESTAMP, ZSTANZAID VARCHAR, ZFROMJID VARCHAR, ZTEXT VARCHAR,
  ZPUSHNAME VARCHAR);
CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZTITLE VARCHAR,
  ZMEDIALOCALPATH VARCHAR, ZFILESIZE INTEGER, ZMETADATA BLOB);
CREATE TABLE ZWAMESSAGEINFO (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZRECEIPTINFO BLOB);
"""

GROUP_JID = "120363000000000001@g.us"
OTHER_GROUP_JID = "120363000000000002@g.us"
PRIVATE_JID = "33600000000@s.whatsapp.net"
T0 = 1_788_000_000  # 2026-08-29 environ


def build(path: Path, wal: bool = True) -> Path:
    """Crée la base factice ; renvoie son chemin."""
    conn = sqlite3.connect(path)
    if wal:
        conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    conn.executemany("INSERT INTO Z_PRIMARYKEY VALUES (?,?,0,0)",
                     [(1, "WAChatSession"), (2, "WAMessage")])
    conn.executemany(
        "INSERT INTO ZWACHATSESSION VALUES (?,?,?,?,?,?,?)",
        [(1, 1, 1, 1, None, GROUP_JID, "Investisseurs Immo"),
         (2, 1, 1, 2, None, OTHER_GROUP_JID, "Club Lecture"),
         (3, 1, 0, None, None, PRIVATE_JID, "Maman")])
    conn.executemany("INSERT INTO ZWAGROUPINFO VALUES (?,?,?,?,?)",
                     [(1, 1, 1, 0, None), (2, 2, 0, 0, None)])
    conn.executemany(
        "INSERT INTO ZWAGROUPMEMBER VALUES (?,?,?,?,?)",
        [(1, 1, "111@lid", "Alice Martin", None),
         (2, 1, "222@s.whatsapp.net", "", None),
         (3, 1, "333@lid", "", None)])
    conn.execute("INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, '222@s.whatsapp.net', 'Bruno')")
    msgs = [
        # pk, chat, member, media, fromme, type, event, date, stanza, fromjid, text
        (1, 1, 1, None, 0, 0, 2, T0, "AAA1", GROUP_JID, "Faut-il vendre avant d'acheter ?"),
        (2, 1, 2, 1, 0, 0, 2, T0 + 60, "AAA2", GROUP_JID, "Non, continue à sourcer."),
        (3, 1, None, None, 1, 0, 2, T0 + 120, "AAA3", None, "Merci !"),
        (4, 1, None, None, 0, 6, 15, T0 + 180, "AAA4", GROUP_JID, None),
        (5, 1, 3, 2, 0, 1, 2, T0 + 240, "AAA5", GROUP_JID, None),
        (6, 2, None, None, 0, 0, 0, T0, "BBB1", "444@lid", "Secret d'un autre groupe"),
        (7, 3, None, None, 0, 0, 0, T0, "CCC1", PRIVATE_JID, "Message privé"),
    ]
    conn.executemany(
        "INSERT INTO ZWAMESSAGE (Z_PK, ZCHATSESSION, ZGROUPMEMBER, ZMEDIAITEM, ZISFROMME,"
        " ZMESSAGETYPE, ZGROUPEVENTTYPE, ZMESSAGEDATE, ZSTANZAID, ZFROMJID, ZTEXT)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        [m[:7] + (core_date(m[7]),) + m[8:] for m in msgs])
    pushname = base64.b64encode(pb_field(1, "Chloé") + pb_field(2, 7)).decode()
    conn.execute("UPDATE ZWAMESSAGE SET ZPUSHNAME = ? WHERE Z_PK = 5", (pushname,))
    reply_meta = pb_field(4, "Faut-il vendre") + pb_field(5, "AAA1") + pb_field(6, "111@lid")
    conn.executemany("INSERT INTO ZWAMEDIAITEM VALUES (?,?,?,?,?,?)",
                     [(1, 2, None, None, None, reply_meta),
                      (2, 5, None, "Media/x.jpg", 1000, pb_field(3, 42))])
    conn.execute("INSERT INTO ZWAMESSAGEINFO VALUES (1, 2, ?)",
                 (pb_field(4, 1) + pb_field(7, pb_field(1, pb_field(1, "RID1") + pb_field(2, "111@lid")
                                                             + pb_field(3, "👍") + pb_field(4, 9))
                                           + pb_field(1, pb_field(1, "RID2") + pb_field(2, "333@lid")
                                                             + pb_field(3, "👍") + pb_field(4, 9))),))
    conn.commit()
    conn.close()
    return path
