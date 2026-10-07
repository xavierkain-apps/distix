import Foundation

public struct PipelineStats: Sendable, Equatable {
    public var windows = 0
    public var fichesCreated = 0
    public var fichesUpdated = 0
    public var merges = 0
    public var usage = LLMUsage()
    public init() {}
}

/// Enchaîne attribution, rédaction, fusion et thèmes pour une conversation (brief § 6.2).
/// Reprend là où il s'était arrêté : les messages non attribués et les fils marqués
/// « à rédiger » sont stockés, rien n'est perdu ni dupliqué en cas d'échec.
public final class Pipeline: @unchecked Sendable {
    let store: Store
    let provider: LLMProvider
    let embedder: EmbeddingProvider
    let settings: AppSettings
    public private(set) var stats = PipelineStats()

    public init(store: Store, provider: LLMProvider, embedder: EmbeddingProvider, settings: AppSettings) {
        self.store = store; self.provider = provider; self.embedder = embedder; self.settings = settings
    }

    private func pseudonymizer(for conversationIds: [String]) throws -> Pseudonymizer {
        var all: [Int64: AuthorRecord] = [:]
        for c in Set(conversationIds) { all.merge(try store.authors(in: c)) { a, _ in a } }
        return Pseudonymizer(authors: all, enabled: settings.pseudonymize)
    }

    public func process(conversationId: String, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let pseudo = try pseudonymizer(for: [conversationId])
        let attributor = ThreadAttributor(store: store, provider: provider, settings: settings)
        let total = try store.pendingCount(in: conversationId)
        while true {
            try Task.checkCancellation()
            let left = try store.pendingCount(in: conversationId)
            if left > 0 {
                progress(String(localized: "Reconstitution des fils : \(total - left)/\(total) messages", bundle: CoreResources.bundle))
            }
            guard try await attributor.processWindow(conversationId: conversationId, pseudo: pseudo,
                                                     usage: &stats.usage) else { break }
            stats.windows += 1
        }
        let threads = try store.threadsNeedingFiche(in: conversationId)
        var done = Set<String>()
        for (i, t) in threads.enumerated() {
            try Task.checkCancellation()
            progress(String(localized: "Rédaction des fiches : \(i + 1)/\(threads.count)", bundle: CoreResources.bundle))
            if let fid = try store.ficheId(forThread: t.id!) {
                guard done.insert(fid).inserted else { continue }
                if try await regenerate(ficheId: fid) { stats.fichesUpdated += 1 }
            } else if let created = try await createFiche(conversationId: conversationId, threadIds: [t.id!], pseudo: pseudo) {
                stats.fichesCreated += 1
                done.insert(created.id)
                if let target = try await findMergeTarget(for: created) {
                    try await merge(created, into: target)
                    done.insert(target)
                }
            }
        }
    }

    // MARK: Création et régénération

    func createFiche(conversationId: String, threadIds: [Int64], pseudo: Pseudonymizer,
                     id: String = UUID().uuidString) async throws -> FicheRecord? {
        let writer = FicheWriter(store: store, provider: provider, settings: settings)
        let result = try await writer.write(conversationId: conversationId, threadIds: threadIds, previous: nil,
                                            pseudo: pseudo, usage: &stats.usage)
        for t in threadIds where !result.threadSummary.isEmpty {
            try store.updateThreadSummary(t, summary: result.threadSummary)
        }
        try store.clearNeedsFiche(threadIds)
        guard let content = result.content else { return nil }
        let messages = try store.messages(ofThreads: threadIds)
        let fiche = FicheRecord(
            id: id, conversationId: conversationId,
            themeId: try store.themeId(named: content.theme, in: conversationId),
            status: content.status, question: content.question,
            content: try JSONEncoder.distix.encode(content),
            embedding: try await embedding(for: content),
            firstMessageAt: messages.first?.sentAt ?? Date(), lastMessageAt: messages.last?.sentAt ?? Date(),
            createdAt: Date(), updatedAt: Date(), readAt: nil, readState: .new, changeNote: nil)
        try store.saveFiche(fiche, threadIds: threadIds)
        return fiche
    }

    /// Régénère une fiche à partir de tous ses fils. Renvoie true si le fond a changé
    /// (la fiche redevient alors non lue).
    @discardableResult
    func regenerate(ficheId: String, forceUnread: Bool = false, note: String? = nil) async throws -> Bool {
        guard var fiche = try store.fiche(ficheId) else { return false }
        let threadIds = try store.threadIds(ofFiche: ficheId)
        let messages = try store.messages(ofThreads: threadIds)
        let pseudo = try pseudonymizer(for: [fiche.conversationId] + messages.map(\.conversationId))
        let writer = FicheWriter(store: store, provider: provider, settings: settings)
        let result = try await writer.write(conversationId: fiche.conversationId, threadIds: threadIds,
                                            previous: fiche.decoded, pseudo: pseudo, usage: &stats.usage)
        try store.clearNeedsFiche(threadIds)
        guard let content = result.content else { return false }
        let changed = forceUnread || result.materialChange
        fiche.content = try JSONEncoder.distix.encode(content)
        fiche.question = content.question
        fiche.status = content.status
        if fiche.themeId == nil { fiche.themeId = try store.themeId(named: content.theme, in: fiche.conversationId) }
        fiche.embedding = try await embedding(for: content)
        fiche.firstMessageAt = messages.first?.sentAt ?? fiche.firstMessageAt
        fiche.lastMessageAt = messages.last?.sentAt ?? fiche.lastMessageAt
        fiche.updatedAt = Date()
        if changed {
            let stillNew = fiche.readAt == nil && fiche.readState == .new
            fiche.readAt = nil
            fiche.readState = stillNew ? .new : .updated
            fiche.changeNote = note ?? (result.changeNote.isEmpty ? nil : result.changeNote)
        }
        try store.saveFiche(fiche, threadIds: threadIds)
        return changed
    }

    func embedding(for c: FicheContent) async throws -> Data? {
        let v = try await embedder.embed([c.question + "\n" + c.context]).first
        return v.map(VectorMath.encode)
    }

    // MARK: Fusion des doublons

    func findMergeTarget(for fiche: FicheRecord) async throws -> String? {
        guard let emb = fiche.embedding.map(VectorMath.decode), let content = fiche.decoded else { return nil }
        let scope = settings.crossGroupMerge ? try store.selectedConversations().map(\.id) : [fiche.conversationId]
        let candidates = try store.fichesWithEmbedding(in: scope, excluding: fiche.id)
            .compactMap { f -> (FicheRecord, Float)? in
                guard let e = f.embedding else { return nil }
                let s = VectorMath.cosine(emb, VectorMath.decode(e))
                return s >= Float(settings.mergeThreshold) ? (f, s) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
        let judge = MergeJudge(provider: provider, settings: settings)
        for (candidate, _) in candidates {
            guard let other = candidate.decoded else { continue }
            if try await judge.sameSubject(content, other, usage: &stats.usage) { return candidate.id }
        }
        return nil
    }

    /// Regroupe les fils de `fiche` sous `target` et régénère la fiche cible.
    func merge(_ fiche: FicheRecord, into target: String) async throws {
        let threads = try store.threadIds(ofFiche: fiche.id)
        try store.moveThreads(threads, from: fiche.id, to: target)
        try store.deleteFiche(fiche.id)
        stats.fichesCreated -= 1
        stats.merges += 1
        try await regenerate(ficheId: target, forceUnread: true,
                             note: String(localized: "Question similaire posée à nouveau, fiche enrichie.", bundle: CoreResources.bundle))
    }

    /// Défait les fusions d'une fiche : chaque fiche d'origine est recréée (avec son
    /// identifiant) à partir de ses fils, puis la fiche restante est régénérée.
    public func undoMerge(ficheId: String) async throws {
        let links = try store.ficheThreads(ficheId).filter { $0.mergedFromFicheId != nil }
        guard !links.isEmpty, let fiche = try store.fiche(ficheId) else { return }
        let groups = Dictionary(grouping: links, by: { $0.mergedFromFicheId! })
        for (originalId, items) in groups {
            let threadIds = items.map(\.threadId)
            let pseudo = try pseudonymizer(for: [fiche.conversationId])
            let writer = FicheWriter(store: store, provider: provider, settings: settings)
            let result = try await writer.write(conversationId: fiche.conversationId, threadIds: threadIds,
                                                previous: nil, pseudo: pseudo, usage: &stats.usage)
            guard let content = result.content else { continue }
            let messages = try store.messages(ofThreads: threadIds)
            let restored = FicheRecord(
                id: originalId, conversationId: fiche.conversationId,
                themeId: try store.themeId(named: content.theme, in: fiche.conversationId),
                status: content.status, question: content.question,
                content: try JSONEncoder.distix.encode(content), embedding: try await embedding(for: content),
                firstMessageAt: messages.first?.sentAt ?? Date(), lastMessageAt: messages.last?.sentAt ?? Date(),
                createdAt: Date(), updatedAt: Date(), readAt: nil, readState: .new, changeNote: nil)
            try store.saveFiche(restored, threadIds: [])
            try store.detachThreads(threadIds, to: originalId)
        }
        try await regenerate(ficheId: ficheId)
    }
}
