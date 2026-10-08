import CryptoKit
import GRDB
import XCTest
@testable import DistiXCore

final class WhatsAppSourceTests: XCTestCase {
    var dir: URL!
    var dbURL: URL!
    var writer: DatabaseQueue!
    var tempRoot: URL { dir.appendingPathComponent("tmp") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("distix-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("ChatStorage.sqlite")
        writer = try FakeWhatsApp.build(at: dbURL)
    }

    override func tearDownWithError() throws {
        writer = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func digest() throws -> [String: String] {
        var out: [String: String] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out[suffix] = SHA256.hash(data: try Data(contentsOf: url)).description
        }
        return out
    }

    func testOriginalFilesUntouchedAndCopyRemoved() async throws {
        let before = try digest()
        XCTAssertNotNil(before["-wal"])
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        _ = try snap.listConversations()
        _ = try snap.fetchMessages(in: FakeWhatsApp.group, after: nil, since: nil)
        snap.close()
        XCTAssertEqual(before, try digest())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])
    }

    func testStaleCopiesArePurged() async throws {
        let stale = tempRoot.appendingPathComponent("distix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("copie oubliée".utf8).write(to: stale.appendingPathComponent("ChatStorage.sqlite"))
        let live = tempRoot.appendingPathComponent("distix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))   // reste d'une synchro interrompue
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))     // copie récente d'un autre processus
        snap.close()
    }

    func testListsOnlyGroups() async throws {
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        defer { snap.close() }
        let names = try snap.listConversations().map(\.name)
        XCTAssertEqual(Set(names), ["Investisseurs Immo", "Club Lecture"])
    }

    func testMessagesOfOneGroupOnly() async throws {
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        defer { snap.close() }
        let msgs = try snap.fetchMessages(in: FakeWhatsApp.group, after: nil, since: nil)
        XCTAssertEqual(msgs.map(\.sourceId), ["AAA1", "AAA2", "AAA3", "AAA4", "AAA5"])
        XCTAssertFalse(msgs.contains { $0.text?.contains("Secret") == true || $0.text?.contains("privé") == true })
    }

    func testAuthorsKindsRepliesReactionsDates() async throws {
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        defer { snap.close() }
        let m = Dictionary(uniqueKeysWithValues: try snap.fetchMessages(in: FakeWhatsApp.group, after: nil, since: nil)
            .map { ($0.sourceId, $0) })
        XCTAssertEqual(m["AAA1"]?.authorId, "111111111@lid")
        XCTAssertEqual(m["AAA1"]?.authorDisplayName, "Alice")           // ZFIRSTNAME (ZCONTACTNAME vide)
        XCTAssertEqual(m["AAA2"]?.authorDisplayName, "Bruno")           // ZWAPROFILEPUSHNAME
        XCTAssertEqual(m["AAA3"]?.authorId, "me")
        XCTAssertEqual(m["AAA5"]?.authorId, "333333333@lid")            // jamais le JID du groupe
        XCTAssertNil(m["AAA5"]?.authorDisplayName)
        XCTAssertEqual(m["AAA2"]?.replyToSourceId, "AAA1")
        XCTAssertNil(m["AAA1"]?.replyToSourceId)
        XCTAssertEqual(m["AAA2"]?.reactionCount, 2)
        XCTAssertEqual(m["AAA4"]?.kind, .system)
        XCTAssertEqual(m["AAA5"]?.kind, .media)
        XCTAssertEqual(m["AAA5"]?.mediaLabel, "image")
        XCTAssertEqual(m["AAA1"]?.sentAt, FakeWhatsApp.t0)
    }

    func testIdentitiesNamesAndSharedPhonesOnly() async throws {
        try FakeWhatsApp.buildIdentities(in: dir)
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO ZWAGROUPMEMBER VALUES (4, 1, '444444444@lid', '', NULL)")
        }
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        defer { snap.close() }
        let a = Dictionary(uniqueKeysWithValues: try snap.listAuthors(in: FakeWhatsApp.group).map { ($0.id, $0) })
        XCTAssertEqual(a["111111111@lid"]?.displayName, "Alice")              // nom WhatsApp avant le nom de compte
        XCTAssertNil(a["111111111@lid"]?.phone)                               // numéro présent mais non partagé
        XCTAssertEqual(a["222222222@s.whatsapp.net"]?.phone, "+222222222")    // adressé par son numéro
        XCTAssertEqual(a["333333333@lid"]?.displayName, "Chloé compte")
        XCTAssertEqual(a["333333333@lid"]?.phone, "+33633333333")             // état de partage 1
        XCTAssertEqual(a["444444444@lid"]?.displayName, "Denise Voisine")     // carnet d'adresses en priorité
        XCTAssertEqual(a["444444444@lid"]?.phone, "+33644444444")
    }

    func testMissingIdentityDatabasesDegradeGracefully() async throws {
        try "pas une base".write(to: dir.appendingPathComponent("LID.sqlite"), atomically: true, encoding: .utf8)
        let snap = try await WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot).snapshot()
        defer { snap.close() }
        let a = Dictionary(uniqueKeysWithValues: try snap.listAuthors(in: FakeWhatsApp.group).map { ($0.id, $0) })
        XCTAssertNil(a["333333333@lid"]?.phone)
        XCTAssertEqual(a["222222222@s.whatsapp.net"]?.displayName, "Bruno")
    }

    func testCursorFollowsInsertionOrderNotDate() async throws {
        let source = WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot)
        var snap = try await source.snapshot()
        let first = try snap.fetchMessages(in: FakeWhatsApp.group, after: nil, since: nil)
        snap.close()
        let cursor = SyncCursor(sequence: first.last!.sequence, date: first.last!.sentAt)
        // Message reçu en retard : inséré après, mais daté d'avant le curseur.
        try await writer.write { db in
            try FakeWhatsApp.insert([.init(pk: 8, chat: 1, member: 2, minutes: -60, stanza: "AAA8", text: "Réponse tardive")], db)
        }
        snap = try await source.snapshot()
        defer { snap.close() }
        let next = try snap.fetchMessages(in: FakeWhatsApp.group, after: cursor, since: nil)
        XCTAssertEqual(next.map(\.sourceId), ["AAA8"])
    }

    func testSchemaChangeIsReportedCleanly() async throws {
        try await writer.write { db in try db.execute(sql: "ALTER TABLE ZWAMESSAGE RENAME COLUMN ZTEXT TO ZBODY") }
        let source = WhatsAppSource(databaseURL: dbURL, tempRoot: tempRoot)
        do {
            _ = try await source.snapshot()
            XCTFail("aurait dû échouer")
        } catch let SourceError.schemaChanged(missing) {
            XCTAssertEqual(missing, ["ZWAMESSAGE.ZTEXT"])
        }
        let status = await source.checkAvailability()
        XCTAssertEqual(status, .schemaChanged(missing: ["ZWAMESSAGE.ZTEXT"]))
    }

    func testMissingDatabase() async {
        let status = await WhatsAppSource(databaseURL: dir.appendingPathComponent("absent.sqlite"), tempRoot: tempRoot).checkAvailability()
        XCTAssertEqual(status, .notInstalled)
    }
}

final class ProtobufTests: XCTestCase {
    func testNestedStrings() {
        let blob = FakeWhatsApp.field(1, int: 7) + FakeWhatsApp.field(5, FakeWhatsApp.field(1, "ID") + FakeWhatsApp.field(2, "x@lid"))
        let s = Protobuf.strings(blob)
        XCTAssertEqual(s.map(\.path), ["5.1", "5.2"])
        XCTAssertEqual(s.map(\.value), ["ID", "x@lid"])
    }

    func testGarbageIsIgnored() {
        XCTAssertTrue(Protobuf.strings(Data([0xFF, 0xFF, 0xFF])).isEmpty)
    }
}

final class PseudonymizerTests: XCTestCase {
    func testMentionsPhonesEmailsButNotAmounts() {
        let a = AuthorRecord(id: 1, conversationId: "c", sourceAuthorId: "111111111@lid", displayName: "Alice",
                             aliasNumber: 3, mentionToken: "111111111")
        let p = Pseudonymizer(authors: [1: a], enabled: true)
        let s = p.clean("Merci @111111111 et @999999999, appelle le 06 12 34 56 78 ou +33 6 12 34 56 78, écris à a.b@c.fr. Prix : 1 250 000 €, 2 500 000.")
        XCTAssertTrue(s.contains("@Membre 3"))
        XCTAssertTrue(s.contains("@[membre]"))
        XCTAssertFalse(s.contains("06 12"))
        XCTAssertFalse(s.contains("+33"))
        XCTAssertFalse(s.contains("a.b@c.fr"))
        XCTAssertTrue(s.contains("1 250 000 €"))
        XCTAssertTrue(s.contains("2 500 000"))
        XCTAssertEqual(p.name(of: 1), "Membre 3")
    }

    func testDisabledKeepsNames() {
        let a = AuthorRecord(id: 1, conversationId: "c", sourceAuthorId: "x@lid", displayName: "Alice", aliasNumber: 3, mentionToken: "x")
        XCTAssertEqual(Pseudonymizer(authors: [1: a], enabled: false).name(of: 1), "Alice")
    }
}
