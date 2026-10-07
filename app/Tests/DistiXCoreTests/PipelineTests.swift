import GRDB
import XCTest
@testable import DistiXCore

/// Pipeline de bout en bout sur base factice, avec un fournisseur d'IA simulé.
final class PipelineTests: XCTestCase {
    var dir: URL!
    var waURL: URL!
    var wa: DatabaseQueue!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("distix-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        waURL = dir.appendingPathComponent("ChatStorage.sqlite")
        wa = try FakeWhatsApp.build(at: waURL, messages: Self.conversation(from: 1, count: 40))
    }

    override func tearDownWithError() throws {
        wa = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Une question toutes les 5 messages, suivie de 4 réponses.
    static func conversation(from start: Int64, count: Int) -> [FakeWhatsApp.Message] {
        (0..<count).map { i in
            let pk = start + Int64(i)
            let isQuestion = (pk - 1) % 5 == 0
            return FakeWhatsApp.Message(
                pk: pk, chat: 1, member: Int64(1 + pk % 3), minutes: Double(pk) * 10, stanza: "S\(pk)",
                text: isQuestion ? "Question numéro \((pk - 1) / 5) sur le financement ?" : "Réponse \(pk) : voici mon avis.",
                replyTo: isQuestion ? nil : "S\(pk - (pk - 1) % 5)")
        }
    }

    func makeEngine(_ llm: StubLLM, store: Store) -> SyncEngine {
        SyncEngine(store: store, source: WhatsAppSource(databaseURL: waURL), embedder: StubEmbedder(), provider: llm)
    }

    var settings: AppSettings {
        var s = AppSettings()
        s.windowSize = 12
        s.windowOverlap = 4
        s.mergeThreshold = 0.99
        return s
    }

    func select(_ store: Store, _ engine: SyncEngine) async throws {
        _ = try await engine.refreshConversations()
        try store.setSelected(ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group), selected: true, historyStart: nil)
    }

    func testEndToEnd() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM()
        llm.sameSubject = false
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        let summary = await engine.run(settings: settings)!
        XCTAssertNil(summary.error)
        XCTAssertEqual(summary.messagesRead, 40)
        XCTAssertEqual(summary.fichesCreated, 8)
        let stats = try store.statistics()
        XCTAssertEqual(stats["messages en attente de traitement"], 0)
        XCTAssertEqual(stats["fiches"], 8)
        XCTAssertEqual(stats["fiches non lues"], 8)
        let fiche = try store.fiches(.init()).first!
        let content = fiche.decoded!
        // « Ne rien inventer » : identifiant inexistant et lien absent des messages écartés.
        XCTAssertFalse(content.answers.flatMap(\.sourceMessageIds).isEmpty)
        XCTAssertTrue(content.answers.flatMap(\.sourceMessageIds).allSatisfy { $0.hasPrefix("S") })
        XCTAssertEqual(content.links, [])
        XCTAssertEqual(try store.themes(in: fiche.conversationId).map(\.name), ["Financement"])
        // Recherche plein texte (insensible aux accents).
        XCTAssertFalse(try store.fiches(.init(search: "numero 3")).isEmpty)
    }

    func testIncrementalMatchesSinglePass() async throws {
        // Traitement en une fois.
        let storeA = Store(try AppDatabase.inMemory())
        let llmA = StubLLM(); llmA.sameSubject = false
        let engineA = makeEngine(llmA, store: storeA)
        try await select(storeA, engineA)
        try await wa.write { db in try FakeWhatsApp.insert(Self.conversation(from: 41, count: 20), db) }
        _ = await engineA.run(settings: settings)

        // Même données, en deux fois.
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wa = try FakeWhatsApp.build(at: waURL, messages: Self.conversation(from: 1, count: 40))
        let storeB = Store(try AppDatabase.inMemory())
        let llmB = StubLLM(); llmB.sameSubject = false
        let engineB = makeEngine(llmB, store: storeB)
        try await select(storeB, engineB)
        _ = await engineB.run(settings: settings)
        try await wa.write { db in try FakeWhatsApp.insert(Self.conversation(from: 41, count: 20), db) }
        let second = await engineB.run(settings: settings)!
        XCTAssertEqual(second.messagesRead, 20)

        let a = try storeA.statistics(), b = try storeB.statistics()
        XCTAssertEqual(a["messages"], b["messages"])
        XCTAssertEqual(a["fiches"], b["fiches"])
        XCTAssertEqual(Set(try storeA.fiches(.init()).map(\.question)), Set(try storeB.fiches(.init()).map(\.question)))
    }

    func testFailureResumesWithoutDuplicates() async throws {
        let store = Store(try AppDatabase.inMemory())
        let failing = StubLLM()
        failing.failAfter = 2
        failing.sameSubject = false
        try await select(store, makeEngine(failing, store: store))
        let first = await makeEngine(failing, store: store).run(settings: settings)!
        XCTAssertNotNil(first.error)
        // Les messages sont stockés et le curseur a avancé ; le reste est en attente.
        XCTAssertEqual(try store.statistics()["messages"], 40)

        let ok = StubLLM(); ok.sameSubject = false
        let second = await makeEngine(ok, store: store).run(settings: settings)!
        XCTAssertNil(second.error)
        XCTAssertEqual(second.messagesRead, 0)
        let stats = try store.statistics()
        XCTAssertEqual(stats["messages"], 40)
        XCTAssertEqual(stats["messages en attente de traitement"], 0)
        XCTAssertEqual(stats["fiches"], 8)
    }

    func testMergeAndUndo() async throws {
        // Deux fois la même question, à des jours d'écart (fils distincts).
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wa = try FakeWhatsApp.build(at: waURL, messages: [
            .init(pk: 1, chat: 1, member: 1, minutes: 0, stanza: "Q1", text: "Comment financer les travaux ?"),
            .init(pk: 2, chat: 1, member: 2, minutes: 1, stanza: "R1", text: "Avec un prêt travaux.", replyTo: "Q1"),
            .init(pk: 3, chat: 1, member: 3, minutes: 20 * 1440, stanza: "Q2", text: "Comment financer les travaux ?"),
            .init(pk: 4, chat: 1, member: 1, minutes: 20 * 1440 + 1, stanza: "R2", text: "Par l'apport personnel.", replyTo: "Q2"),
        ])
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM()
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        let summary = await engine.run(settings: settings)!
        XCTAssertNil(summary.error)
        XCTAssertEqual(summary.merges, 1)
        let fiches = try store.fiches(.init())
        XCTAssertEqual(fiches.count, 1)
        XCTAssertEqual(try store.threadIds(ofFiche: fiches[0].id).count, 2)

        try await engine.undoMerge(ficheId: fiches[0].id, settings: settings)
        XCTAssertEqual(try store.fiches(.init()).count, 2)
        XCTAssertTrue(try store.ficheThreads(fiches[0].id).allSatisfy { $0.mergedFromFicheId == nil })
    }

    func testRewordingDoesNotMarkUnread() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM(); llm.sameSubject = false
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        _ = await engine.run(settings: settings)
        try store.markAllRead()

        // Nouvelle réponse dans un fil existant, jugée sans contenu nouveau.
        llm.materialChange = false
        try await wa.write { db in
            try FakeWhatsApp.insert([.init(pk: 41, chat: 1, member: 1, minutes: 401, stanza: "S41", text: "Je confirme.", replyTo: "S36")], db)
        }
        let s1 = await engine.run(settings: settings)!
        XCTAssertEqual(s1.fichesUpdated, 0)
        XCTAssertEqual(try store.statistics()["fiches non lues"], 0)

        // Même chose, jugée avec contenu nouveau : la fiche redevient « mise à jour ».
        llm.materialChange = true
        try await wa.write { db in
            try FakeWhatsApp.insert([.init(pk: 42, chat: 1, member: 2, minutes: 402, stanza: "S42", text: "Autre avis.", replyTo: "S36")], db)
        }
        let s2 = await engine.run(settings: settings)!
        XCTAssertEqual(s2.fichesUpdated, 1)
        let unread = try store.fiches(.init(unreadOnly: true))
        XCTAssertEqual(unread.count, 1)
        XCTAssertEqual(unread.first?.readState, .updated)
        XCTAssertEqual(unread.first?.changeNote, "Nouvelle réponse.")
    }

    func testWideningHistoryBackfills() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM(); llm.sameSubject = false
        let engine = makeEngine(llm, store: store)
        _ = try await engine.refreshConversations()
        let id = ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group)
        // Seuls les messages des 100 dernières minutes environ (pk >= 31).
        try store.setSelected(id, selected: true, historyStart: FakeWhatsApp.t0.addingTimeInterval(305 * 60))
        let first = await engine.run(settings: settings)!
        XCTAssertEqual(first.messagesRead, 10)
        // Profondeur élargie à tout l'historique : les 30 plus anciens sont récupérés.
        try store.setSelected(id, selected: true, historyStart: nil)
        let second = await engine.run(settings: settings)!
        XCTAssertNil(second.error)
        XCTAssertEqual(second.messagesRead, 30)
        XCTAssertEqual(try store.statistics()["messages"], 40)
        XCTAssertEqual(try store.statistics()["messages en attente de traitement"], 0)
    }

    func testSkippedThreadsAreCountedWithReason() async throws {
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wa = try FakeWhatsApp.build(at: waURL, messages: [
            .init(pk: 1, chat: 1, member: 1, minutes: 0, stanza: "Q1", text: "Simple bavardage ?"),
            .init(pk: 2, chat: 1, member: 2, minutes: 1, stanza: "R1", text: "Oui.", replyTo: "Q1"),
            .init(pk: 3, chat: 1, member: 3, minutes: 2, stanza: "Q2", text: "Quel matériel prévoir ?"),
            .init(pk: 4, chat: 1, member: 1, minutes: 3, stanza: "R2", text: "Une voile de 9 m².", replyTo: "Q2"),
        ])
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM(); llm.sameSubject = false
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        let summary = await engine.run(settings: settings)!
        XCTAssertNil(summary.error)
        XCTAssertEqual(summary.messagesProcessed, 4)
        XCTAssertEqual(summary.fichesCreated, 1)
        XCTAssertEqual(summary.threadsSkipped, 1)
        XCTAssertEqual(try store.statistics()["fils écartés (sans fiche)"], 1)
        XCTAssertEqual(try store.threads(in: nil).compactMap(\.thread.skipReason), ["bavardage"])
        XCTAssertEqual(try store.lastRun()?.threadsSkipped, 1)
    }

    func testExportAndDeleteGroupData() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM(); llm.sameSubject = false
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        _ = await engine.run(settings: settings)
        let out = dir.appendingPathComponent("export")
        let n = try MarkdownExporter(store: store, showRealNames: false).export(try store.fiches(.init()), to: out, includeSources: true)
        XCTAssertEqual(n, 8)
        let file = try FileManager.default.subpathsOfDirectory(atPath: out.path).first { $0.hasSuffix(".md") }!
        let md = try String(contentsOf: out.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("---\ntitle: "))
        XCTAssertTrue(md.contains("theme: \"Financement\""))
        XCTAssertTrue(md.contains("Messages sources"))
        XCTAssertFalse(md.contains("Alice"))                // alias par défaut

        let id = ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group)
        try store.deleteData(of: id)
        let stats = try store.statistics()
        XCTAssertEqual(stats["messages"], 0)
        XCTAssertEqual(stats["fiches"], 0)
        XCTAssertNil(try store.conversation(id)?.cursorSequence)
        XCTAssertTrue(try store.fiches(.init(search: "financement")).isEmpty)
    }
}
