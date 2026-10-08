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

    func testPerGroupSyncInterval() throws {
        let now = Date()
        var c = ConversationRecord(id: "w:g", source: "w", sourceId: "g", name: "g", selected: true, messageCount: 0,
                                   lastMessageAt: nil, historyStart: nil, cursorSequence: nil, cursorDate: nil,
                                   lastSyncedAt: nil, syncIntervalHours: nil)
        XCTAssertTrue(c.isDue(globalIntervalHours: 3, now: now))           // jamais synchronisé
        c.lastSyncedAt = now.addingTimeInterval(-3600)
        XCTAssertFalse(c.isDue(globalIntervalHours: 3, now: now))          // global : 3 h
        c.syncIntervalHours = 0.25
        XCTAssertTrue(c.isDue(globalIntervalHours: 3, now: now))           // le réglage du groupe prime
        c.syncIntervalHours = 6
        XCTAssertFalse(c.isDue(globalIntervalHours: 0.25, now: now))
    }

    func testWatchModeFindsOpportunitiesWithContact() async throws {
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wa = try FakeWhatsApp.build(at: waURL, messages: [
            .init(pk: 1, chat: 1, member: 2, minutes: 0, stanza: "A1", text: "Je cherche un T2 à Lyon pour novembre, 06 12 34 56 78"),
            .init(pk: 2, chat: 1, member: 1, minutes: 1, stanza: "A2", text: "Bonne journée à tous"),
            .init(pk: 3, chat: 1, member: 3, minutes: 2, stanza: "A3", text: "Je cherche une colocation"),
        ])
        let store = Store(try AppDatabase.inMemory())
        let llm = StubLLM()
        let engine = makeEngine(llm, store: store)
        try await select(store, engine)
        let id = ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group)

        // Sans critères : rien n'est envoyé au modèle, les messages restent en attente.
        try store.setGoal(id, mode: .watch, focus: "  ")
        let empty = await engine.run(settings: settings)!
        XCTAssertNil(empty.error)
        XCTAssertEqual(llm.calls, [])
        XCTAssertEqual(try store.statistics()["messages en attente de traitement"], 3)

        try store.setGoal(id, mode: .watch, focus: "Je loue un T2 à Lyon.")
        let summary = await engine.run(settings: settings)!
        XCTAssertNil(summary.error)
        XCTAssertEqual(summary.opportunities, 2)
        XCTAssertEqual(summary.fichesCreated, 0)
        XCTAssertEqual(llm.calls, ["veille"])
        let opps = try store.opportunities(unreadOnly: true)
        XCTAssertEqual(opps.count, 2)
        // Coordonnées : numéro connu pour un membre @s.whatsapp.net, pas pour un @lid.
        let byText = Dictionary(uniqueKeysWithValues: try opps.map { (try store.message($0.messageId)!.sourceId, $0) })
        let bruno = try store.author(try store.message(byText["A1"]!.messageId)!.authorId)!
        XCTAssertEqual(bruno.displayName, "Bruno")
        XCTAssertEqual(bruno.phone, "+222222222")
        XCTAssertNil(try store.author(try store.message(byText["A3"]!.messageId)!.authorId)!.phone)
        // Le numéro présent dans le texte n'a pas été envoyé au modèle.
        XCTAssertEqual(try store.unreadCounts()[id], 2)
        try store.markOpportunityRead(opps[0].id!, read: true)
        XCTAssertEqual(try store.opportunities(unreadOnly: true).count, 1)
    }

    func testFocusIsSentToTheModel() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = RecordingLLM(base: StubLLM())
        let engine = SyncEngine(store: store, source: WhatsAppSource(databaseURL: waURL), embedder: StubEmbedder(), provider: llm)
        try await select(store, engine)
        try store.setGoal(ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group), mode: .knowledge,
                          focus: "Surtout le financement.")
        _ = await engine.run(settings: settings)
        XCTAssertFalse(llm.prompts.isEmpty)
        XCTAssertTrue(llm.prompts.filter { !$0.contains("FICHE A") }.allSatisfy { $0.contains("Surtout le financement.") })
    }

    func testLanguageInstructionAndTranslation() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = RecordingLLM(base: StubLLM())
        let engine = SyncEngine(store: store, source: WhatsAppSource(databaseURL: waURL), embedder: StubEmbedder(), provider: llm)
        try await select(store, engine)
        let id = ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group)
        var s = settings
        s.ficheLanguage = "en"                                   // réglage global
        try store.setLanguage(id, language: "")                  // le groupe garde la langue d'origine
        _ = await engine.run(settings: s)
        let fichePrompts = llm.prompts.filter { $0.contains("MESSAGES DU FIL") }
        XCTAssertFalse(fichePrompts.isEmpty)
        XCTAssertTrue(fichePrompts.allSatisfy { $0.contains("Ne traduis pas") })

        let f = try store.fiches(.init()).first!
        try await engine.translate(ficheId: f.id, to: "en", settings: s)
        let t = try store.fiche(f.id)!
        XCTAssertEqual(t.translationLanguage, "en")
        XCTAssertNotNil(t.decodedTranslation)
        XCTAssertEqual(t.decoded, f.decoded)                     // l'original est conservé
    }

    func testReviewThemesObjectiveAndModel() async throws {
        let store = Store(try AppDatabase.inMemory())
        let llm = RecordingLLM(base: StubLLM())
        let engine = SyncEngine(store: store, source: WhatsAppSource(databaseURL: waURL), embedder: StubEmbedder(), provider: llm)
        try await select(store, engine)
        let id = ConversationRecord.makeId(source: "whatsapp", sourceId: FakeWhatsApp.group)
        try store.saveTheme(id: nil, conversationId: id, name: "Matériel", objective: "Noms exacts des voiles et réglages")
        _ = await engine.run(settings: settings)
        XCTAssertTrue(llm.prompts.contains { $0.contains("Matériel (objectif : Noms exacts des voiles et réglages)") })

        let all = try store.fiches(.init())
        XCTAssertEqual(all.count, 8)
        XCTAssertTrue(all.allSatisfy { $0.model == "recording · \(settings.effectiveFicheModel())" })
        try store.setReview(all[0].id, .validated)
        try store.setReview(all[1].id, .discarded)
        XCTAssertEqual(try store.fiches(.init()).count, 7)                         // écartées masquées
        XCTAssertEqual(try store.fiches(.init(review: .validated)).map(\.id), [all[0].id])
        XCTAssertEqual(try store.fiches(.init(review: .discarded)).map(\.id), [all[1].id])
        XCTAssertEqual(try store.fiches(.init(review: .toReview)).count, 6)
        XCTAssertNotNil(try store.fiche(all[1].id)?.readAt)                       // écartée = lue

        try await engine.regenerate(ficheId: all[0].id, provider: .claudeCode, model: "opus", settings: settings)
        let regenerated = try store.fiche(all[0].id)!
        XCTAssertEqual(regenerated.model, "recording · opus")
        XCTAssertEqual(regenerated.review, .validated)                            // le tri est conservé
    }

    func testThemeNameCleanedAndLanguageDetected() {
        XCTAssertEqual(FicheWriter.cleanTheme("Matériel (objectif : réglages)"), "Matériel")
        XCTAssertEqual(FicheWriter.cleanTheme(""), "Divers")
        XCTAssertEqual(FicheLanguage.detect(["Which wing should I buy for thermals? The new one is great for beginners."]), "en")
        let instruction = FicheLanguage.instruction("", messages: ["Which wing should I buy for thermals? I fly every weekend."])
        XCTAssertTrue(instruction.contains("anglais"))
        XCTAssertTrue(instruction.contains("ne traduis pas"))
        XCTAssertTrue(FicheLanguage.instruction("es", messages: []).contains("espagnol"))
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
