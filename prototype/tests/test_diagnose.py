import hashlib
import io
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

from prototype import diagnose
from prototype.tests import fake_db


def digest(paths):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.exists()}


class DiagnoseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.db = fake_db.build(self.dir / "ChatStorage.sqlite")
        # Une connexion d'écriture ouverte garde le WAL non fusionné, comme WhatsApp.
        self.writer = sqlite3.connect(self.db)
        self.writer.execute("PRAGMA journal_mode=WAL")
        self.writer.execute("UPDATE ZWACHATSESSION SET ZLASTMESSAGEDATE = 1 WHERE Z_PK = 3")
        self.writer.commit()
        self.addCleanup(self.writer.close)
        diagnose.DATA_DIR = self.dir / "data"

    def run_cli(self, *argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = diagnose.main(["--db", str(self.db), *argv])
        return code, buf.getvalue()

    def test_original_files_untouched_and_copy_removed(self):
        files = diagnose._companions(self.db)
        before = digest(files)
        self.assertIn("ChatStorage.sqlite-wal", before)
        for cmd in (["report"], ["groups"], ["messages", "Immo"], ["chat-props", "Immo"]):
            code, _ = self.run_cli(*cmd)
            self.assertEqual(code, 0, cmd)
        self.assertEqual(before, digest(files))
        leftovers = [p for p in (self.dir / "data" / "tmp").iterdir()]
        self.assertEqual(leftovers, [])

    def test_copy_sees_uncheckpointed_wal(self):
        with diagnose.open_copy(self.db) as conn:
            v = conn.execute("SELECT ZLASTMESSAGEDATE FROM ZWACHATSESSION WHERE Z_PK=3").fetchone()[0]
        self.assertEqual(v, 1)

    def test_copy_is_read_only(self):
        with diagnose.open_copy(self.db) as conn:
            with self.assertRaises(sqlite3.OperationalError):
                conn.execute("DELETE FROM ZWAMESSAGE")

    def test_groups_lists_only_groups(self):
        _, out = self.run_cli("groups")
        self.assertIn("Investisseurs Immo", out)
        self.assertIn("Club Lecture", out)
        self.assertNotIn("Maman", out)

    def test_messages_only_from_selected_group(self):
        _, out = self.run_cli("messages", "immo")
        self.assertIn("Faut-il vendre", out)
        self.assertNotIn("Secret d'un autre groupe", out)
        self.assertNotIn("Message privé", out)

    def test_messages_authors_and_reply(self):
        with diagnose.open_copy(self.db) as conn:
            msgs = diagnose.recent_messages(conn, 1)
        by_pk = {m["pk"]: m for m in msgs}
        self.assertEqual(by_pk[1]["author"], "Alice Martin")
        self.assertEqual(by_pk[1]["author_source"], "ZWAGROUPMEMBER.ZCONTACTNAME")
        self.assertEqual(by_pk[2]["author"], "Bruno")       # ZCONTACTNAME vide -> profil
        self.assertEqual(by_pk[2]["author_source"], "ZWAPROFILEPUSHNAME")
        self.assertEqual(by_pk[3]["author"], "moi")
        # ZPUSHNAME n'est pas un nom : sans profil, on retombe sur le JID du membre,
        # jamais sur le JID du groupe.
        self.assertEqual(by_pk[5]["author"], "333@lid")
        self.assertEqual(by_pk[5]["author_source"], "aucun")
        self.assertEqual(by_pk[2]["reply_to"], "AAA1")
        self.assertIsNone(by_pk[1]["reply_to"])
        self.assertEqual(by_pk[2]["reactions"], {"👍": 2})

    def test_core_data_date(self):
        dt = diagnose.to_datetime(fake_db.core_date(fake_db.T0))
        self.assertEqual(dt, datetime.fromtimestamp(fake_db.T0, tz=timezone.utc))

    def test_report_has_no_message_content_nor_names(self):
        _, out = self.run_cli("report")
        for secret in ("Faut-il vendre", "continue à sourcer", "Secret", "Message privé",
                       "Investisseurs", "Club Lecture", "Maman", "Alice", "Bruno", "Chloé",
                       "AAA1", "111@lid", "👍", "RID1"):
            self.assertNotIn(secret, out, secret)
        self.assertIn("id_message_connu", out)          # lien de réponse détecté
        self.assertIn("type 0 : 1/1", out)
        self.assertIn("emoji", out)                     # réaction détectée
        self.assertIn("1 messages de groupe ont au moins une réaction, 2 réactions", out)
        self.assertIn("base64+protobuf = 1", out)

    def test_schema_change_is_reported_cleanly(self):
        self.writer.execute("ALTER TABLE ZWAMESSAGE RENAME COLUMN ZTEXT TO ZBODY")
        self.writer.commit()
        code, out = self.run_cli("messages", "immo")
        self.assertEqual(code, 2)
        code, out = self.run_cli("report")
        self.assertEqual(code, 0)
        self.assertIn("ZWAMESSAGE.ZTEXT", out)
        self.assertIn("Schéma incompatible", out)

    def test_ambiguous_and_unknown_group(self):
        self.assertEqual(self.run_cli("messages", "zzz")[0], 2)
        self.assertEqual(self.run_cli("messages", "u")[0], 2)  # « u » dans les deux noms

    def test_missing_db(self):
        code = diagnose.main(["--db", str(self.dir / "absent.sqlite"), "groups"])
        self.assertEqual(code, 2)


class ProtobufTest(unittest.TestCase):
    def test_nested_strings(self):
        blob = fake_db.pb_field(1, 7) + fake_db.pb_field(5, fake_db.pb_field(1, "ID") + fake_db.pb_field(2, "x@lid"))
        self.assertEqual(diagnose.pb_strings(blob), [("5.1", "ID"), ("5.2", "x@lid")])

    def test_garbage_is_ignored(self):
        self.assertEqual(diagnose.pb_strings(b"\xff\xff\xff"), [])
        self.assertEqual(diagnose.pb_strings("not bytes"), [])


if __name__ == "__main__":
    unittest.main()
