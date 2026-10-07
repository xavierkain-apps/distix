import Foundation
import GRDB
@testable import DistiXCore

/// Base factice au format de ChatStorage.sqlite, alignée sur docs/schema-whatsapp.md.
/// Aucune donnée réelle.
enum FakeWhatsApp {
    static let group = "120363000000000001@g.us"
    static let otherGroup = "120363000000000002@g.us"
    static let privateChat = "33600000000@s.whatsapp.net"
    static let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    static func varint(_ n: UInt64) -> Data {
        var n = n, out = Data()
        repeat {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    static func field(_ number: Int, _ value: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(value.count)) + value
    }

    static func field(_ number: Int, _ value: String) -> Data { field(number, Data(value.utf8)) }

    static func field(_ number: Int, int value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }

    struct Message {
        var pk: Int64
        var chat: Int64
        var member: Int64?
        var fromMe = false
        var type = 0
        var minutes: Double
        var stanza: String
        var text: String?
        var replyTo: String? = nil
        var reactions = 0
    }

    static let defaultMessages: [Message] = [
        Message(pk: 1, chat: 1, member: 1, minutes: 0, stanza: "AAA1", text: "Faut-il vendre avant d'acheter le bien suivant ?"),
        Message(pk: 2, chat: 1, member: 2, minutes: 1, stanza: "AAA2", text: "Non, continue à sourcer pendant les travaux.", replyTo: "AAA1", reactions: 2),
        Message(pk: 3, chat: 1, member: nil, fromMe: true, minutes: 2, stanza: "AAA3", text: "Merci @111111111 !"),
        Message(pk: 4, chat: 1, member: nil, type: 6, minutes: 3, stanza: "AAA4", text: nil),
        Message(pk: 5, chat: 1, member: 3, type: 1, minutes: 4, stanza: "AAA5", text: nil),
        Message(pk: 6, chat: 2, member: nil, minutes: 0, stanza: "BBB1", text: "Secret d'un autre groupe"),
        Message(pk: 7, chat: 3, member: nil, minutes: 0, stanza: "CCC1", text: "Message privé"),
    ]

    /// Crée la base (en mode WAL, comme WhatsApp) et renvoie une connexion d'écriture
    /// qui garde le WAL ouvert.
    @discardableResult
    static func build(at url: URL, messages: [Message] = defaultMessages) throws -> DatabaseQueue {
        let q = try DatabaseQueue(path: url.path)
        try q.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
                CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZSESSIONTYPE INTEGER, ZGROUPINFO INTEGER,
                  ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR, ZLASTMESSAGEDATE TIMESTAMP);
                CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR,
                  ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
                CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
                CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER,
                  ZMEDIAITEM INTEGER, ZMESSAGEINFO INTEGER, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER,
                  ZGROUPEVENTTYPE INTEGER, ZMESSAGEDATE TIMESTAMP, ZSTANZAID VARCHAR, ZFROMJID VARCHAR,
                  ZTEXT VARCHAR, ZPUSHNAME VARCHAR);
                CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZTITLE VARCHAR, ZMETADATA BLOB);
                CREATE TABLE ZWAMESSAGEINFO (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZRECEIPTINFO BLOB);
                """)
            try db.execute(sql: "INSERT INTO ZWACHATSESSION VALUES (1, 1, 1, ?, 'Investisseurs Immo', NULL)", arguments: [group])
            try db.execute(sql: "INSERT INTO ZWACHATSESSION VALUES (2, 1, 2, ?, 'Club Lecture', NULL)", arguments: [otherGroup])
            try db.execute(sql: "INSERT INTO ZWACHATSESSION VALUES (3, 0, NULL, ?, 'Maman', NULL)", arguments: [privateChat])
            try db.execute(sql: """
                INSERT INTO ZWAGROUPMEMBER VALUES (1, 1, '111111111@lid', '', 'Alice');
                INSERT INTO ZWAGROUPMEMBER VALUES (2, 1, '222222222@s.whatsapp.net', '', NULL);
                INSERT INTO ZWAGROUPMEMBER VALUES (3, 1, '333333333@lid', '', NULL);
                INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, '222222222@s.whatsapp.net', 'Bruno');
                """)
            try insert(messages, db)
        }
        return q
    }

    /// LID.sqlite et ContactsV2.sqlite factices, à côté de ChatStorage.sqlite.
    static func buildIdentities(in dir: URL) throws {
        let lid = try DatabaseQueue(path: dir.appendingPathComponent("LID.sqlite").path)
        try lid.write { db in
            try db.execute(sql: """
                CREATE TABLE ZWAZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZCURRENTPHONENUMBERSHARINGSTATE INTEGER,
                  ZIDENTIFIER VARCHAR, ZDISPLAYNAME VARCHAR, ZPHONENUMBER VARCHAR);
                INSERT INTO ZWAZACCOUNT VALUES (1, 0, '111111111@lid', 'Alice compte', '33611111111');
                INSERT INTO ZWAZACCOUNT VALUES (2, 1, '333333333@lid', 'Chloé compte', '33 6 33 33 33 33');
                INSERT INTO ZWAZACCOUNT VALUES (3, 0, '444444444@lid', NULL, NULL);
                """)
        }
        let contacts = try DatabaseQueue(path: dir.appendingPathComponent("ContactsV2.sqlite").path)
        try contacts.write { db in
            try db.execute(sql: """
                CREATE TABLE ZWAADDRESSBOOKCONTACT (Z_PK INTEGER PRIMARY KEY, ZLID VARCHAR, ZWHATSAPPID VARCHAR,
                  ZFULLNAME VARCHAR, ZPHONENUMBER VARCHAR);
                INSERT INTO ZWAADDRESSBOOKCONTACT VALUES (1, '444444444@lid', '33644444444@s.whatsapp.net',
                  'Denise Voisine', '+33 6 44 44 44 44');
                """)
        }
    }

    static func insert(_ messages: [Message], _ db: Database) throws {
        let chatJid: [Int64: String] = [1: group, 2: otherGroup, 3: privateChat]
        for m in messages {
            var meta = field(1, int: 0)
            if let r = m.replyTo { meta += field(5, r) + field(6, "111111111@lid") }
            try db.execute(sql: "INSERT INTO ZWAMEDIAITEM (Z_PK, ZMESSAGE, ZMETADATA) VALUES (?, ?, ?)",
                           arguments: [m.pk, m.pk, meta])
            var info: Data? = nil
            if m.reactions > 0 {
                var reacts = Data()
                for i in 0..<m.reactions { reacts += field(1, field(1, "R\(i)") + field(2, "\(i)@lid") + field(3, "👍")) }
                info = field(4, int: 1) + field(7, reacts)
            }
            try db.execute(sql: "INSERT INTO ZWAMESSAGEINFO (Z_PK, ZMESSAGE, ZRECEIPTINFO) VALUES (?, ?, ?)",
                           arguments: [m.pk, m.pk, info])
            try db.execute(sql: """
                INSERT INTO ZWAMESSAGE (Z_PK, ZCHATSESSION, ZGROUPMEMBER, ZMEDIAITEM, ZMESSAGEINFO, ZISFROMME,
                  ZMESSAGETYPE, ZGROUPEVENTTYPE, ZMESSAGEDATE, ZSTANZAID, ZFROMJID, ZTEXT, ZPUSHNAME)
                VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?, ?, ?, ?, 'Cg==')
                """, arguments: [m.pk, m.chat, m.member, m.pk, m.pk, m.fromMe ? 1 : 0, m.type,
                                 t0.addingTimeInterval(m.minutes * 60).timeIntervalSinceReferenceDate,
                                 m.stanza, m.fromMe ? nil : chatJid[m.chat], m.text])
        }
    }
}
