import Foundation

public struct PipelineStats: Sendable, Equatable {
    public var windows = 0
    public var fichesCreated = 0
    public var fichesUpdated = 0
    public var merges = 0
    public var opportunities = 0
    public var messagesProcessed = 0
    public var threadsSkipped = 0
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
        let conversation = try store.conversation(conversationId)
        let total = try store.pendingCount(in: conversationId)
        stats.messagesProcessed += total
        if conversation?.mode == .watch {
            try await watch(conversationId: conversationId, criteria: conversation?.focus ?? "",
                            pseudo: pseudo, total: total, progress: progress)
            return
        }
        let attributor = ThreadAttributor(store: store, provider: provider, settings: settings)
        while true {
            try Task.checkCancellation()
            let left = try store.pendingCount(in: conversationId)
            if left > 0 {
                progress(String(localized: "Reconstitution des fils : \(total - left)/\(total) messages", bundle: CoreResources.bundle))
            }
            guard try await attributor.processWindow(conversationId: conversationId, pseudo: pseudo,
                                                     focus: conversation?.focus, usage: &stats.usage) else { break }
            stats.windows += 1
        }
        try await writeFiches(conversationId: conversationId, pseudo: pseudo, progress: progress)
    }

    /// Mode veille : sans critères, rien n'est envoyé au modèle et les messages restent en attente.
    private func watch(conversationId: String, criteria: String, pseudo: Pseudonymizer, total: Int,
                       progress: @Sendable (String) -> Void) async throws {
        guard !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stats.messagesProcessed -= total
            progress(String(localized: "Veille : critères non renseignés, groupe ignoré", bundle: CoreResources.bundle))
            return
        }
        let finder = OpportunityFinder(store: store, provider: provider, settings: settings)
        while true {
            try Task.checkCancellation()
            let left = try store.pendingCount(in: conversationId)
            if left > 0 {
                progress(String(localized: "Veille : \(total - left)/\(total) messages examinés", bundle: CoreResources.bundle))
            }
            guard let found = try await finder.processWindow(conversationId: conversationId, criteria: criteria,
                                                              pseudo: pseudo, usage: &stats.usage) else { break }
            stats.opportunities += found
            stats.windows += 1
        }
    }

    private enum Job: Sendable {
        case create(Int64)
        case regenerate(String)
    }

    /// Rédige les fiches des fils modifiés, plusieurs à la fois, puis cherche les
    /// doublons parmi les nouvelles fiches (dans l'ordre chronologique).
    private func writeFiches(conversationId: String, pseudo: Pseudonymizer,
                             progress: @Sendable (String) -> Void) async throws {
        var jobs: [Job] = []
        var seen = Set<String>()
        for t in try store.threadsNeedingFiche(in: conversationId) {
            if let fid = try store.ficheId(forThread: t.id!) {
                if seen.insert(fid).inserted { jobs.append(.regenerate(fid)) }
            } else {
                jobs.append(.create(t.id!))
            }
        }
        guard !jobs.isEmpty else { return }
        var created: [FicheRecord] = []
        var finished = 0
        try await withThrowingTaskGroup(of: (FicheRecord?, Bool, LLMUsage, Bool).self) { group in
            var pending = jobs[...]
            func enqueue(_ job: Job) {
                group.addTask { [self] in
                    var usage = LLMUsage()
                    switch job {
                    case .create(let threadId):
                        let fiche = try await createFiche(conversationId: conversationId, threadIds: [threadId],
                                                          pseudo: pseudo, usage: &usage)
                        return (fiche, false, usage, fiche == nil)
                    case .regenerate(let id):
                        let changed = try await regenerate(ficheId: id, usage: &usage)
                        return (nil, changed, usage, false)
                    }
                }
            }
            for _ in 0..<max(1, settings.concurrency) {
                if let job = pending.popFirst() { enqueue(job) }
            }
            while let (fiche, changed, usage, skipped) = try await group.next() {
                if skipped { stats.threadsSkipped += 1 }
                stats.usage += usage
                finished += 1
                if let fiche { created.append(fiche); stats.fichesCreated += 1 }
                if changed { stats.fichesUpdated += 1 }
                progress(String(localized: "Rédaction des fiches : \(finished)/\(jobs.count)", bundle: CoreResources.bundle))
                if let job = pending.popFirst() { enqueue(job) }
            }
        }
        for fiche in created.sorted(by: { $0.firstMessageAt < $1.firstMessageAt }) {
            try Task.checkCancellation()
            guard let current = try store.fiche(fiche.id) else { continue }   // déjà fusionnée
            if let target = try await findMergeTarget(for: current) {
                try await merge(current, into: target)
            }
        }
    }

    // MARK: Création et régénération

    func createFiche(conversationId: String, threadIds: [Int64], pseudo: Pseudonymizer,
                     usage: inout LLMUsage) async throws -> FicheRecord? {
        let writer = FicheWriter(store: store, provider: provider, settings: settings)
        let result = try await writer.write(conversationId: conversationId, threadIds: threadIds, previous: nil,
                                            pseudo: pseudo, usage: &usage)
        for t in threadIds where !result.threadSummary.isEmpty {
            try store.updateThreadSummary(t, summary: result.threadSummary)
        }
        try store.clearNeedsFiche(threadIds)
        try store.setSkipReason(threadIds, reason: result.skipReason)
        guard let content = result.content else { return nil }
        let messages = try store.messages(ofThreads: threadIds)
        let fiche = FicheRecord(
            id: UUID().uuidString, conversationId: conversationId,
            themeId: try store.themeId(named: content.theme, in: conversationId),
            status: content.status, question: content.question,
            content: try JSONEncoder.distix.encode(content),
            embedding: try await embedding(for: content),
            firstMessageAt: messages.first?.sentAt ?? Date(), lastMessageAt: messages.last?.sentAt ?? Date(),
            createdAt: Date(), updatedAt: Date(), readAt: nil, readState: .new, changeNote: nil,
            translation: nil, translationLanguage: nil, review: nil, model: writer.modelLabel)
        try store.saveFiche(fiche, threadIds: threadIds)
        return fiche
    }

    /// Régénère une fiche à partir de tous ses fils. Renvoie true si le fond a changé
    /// (la fiche redevient alors non lue).
    @discardableResult
    func regenerate(ficheId: String, forceUnread: Bool = false, note: String? = nil, model: String? = nil,
                    usage: inout LLMUsage) async throws -> Bool {
        guard var fiche = try store.fiche(ficheId) else { return false }
        let threadIds = try store.threadIds(ofFiche: ficheId)
        let messages = try store.messages(ofThreads: threadIds)
        let pseudo = try pseudonymizer(for: [fiche.conversationId] + messages.map(\.conversationId))
        let writer = FicheWriter(store: store, provider: provider, settings: settings, modelOverride: model)
        // Régénération demandée avec un autre modèle : on repart de zéro, sans la version précédente.
        let result = try await writer.write(conversationId: fiche.conversationId, threadIds: threadIds,
                                            previous: model == nil ? fiche.decoded : nil, pseudo: pseudo, usage: &usage)
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
        fiche.model = writer.modelLabel
        if model != nil, let tid = try? store.themeId(named: content.theme, in: fiche.conversationId) { fiche.themeId = tid }
        fiche.translation = nil            // traduction périmée
        fiche.translationLanguage = nil
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

    /// Regroupe deux fiches : la plus récente rejoint la plus ancienne, qui est régénérée.
    func merge(_ fiche: FicheRecord, into candidateId: String) async throws {
        guard let candidate = try store.fiche(candidateId) else { return }
        let (source, target) = candidate.firstMessageAt <= fiche.firstMessageAt ? (fiche, candidate) : (candidate, fiche)
        let threads = try store.threadIds(ofFiche: source.id)
        try store.moveThreads(threads, from: source.id, to: target.id)
        try store.deleteFiche(source.id)
        stats.fichesCreated -= 1
        stats.merges += 1
        var usage = LLMUsage()
        try await regenerate(ficheId: target.id, forceUnread: true,
                             note: String(localized: "Question similaire posée à nouveau, fiche enrichie.", bundle: CoreResources.bundle),
                             usage: &usage)
        stats.usage += usage
    }

    /// Régénère une fiche avec un modèle choisi par l'utilisateur.
    public func regenerate(ficheId: String, model: String) async throws {
        var usage = LLMUsage()
        try await regenerate(ficheId: ficheId, model: model, usage: &usage)
        stats.usage += usage
    }

    /// Traduit une fiche à la demande ; l'original est conservé.
    public func translate(ficheId: String, to language: String) async throws {
        guard let fiche = try store.fiche(ficheId), let content = fiche.decoded else { return }
        let source = String(data: try JSONEncoder.distix.encode(content), encoding: .utf8) ?? "{}"
        let request = LLMRequest(
            system: "Tu traduis une fiche de connaissance en \(FicheLanguage.name(language)). Traduis tous les textes, "
                + "garde la structure, les valeurs de status et support, les identifiants et les liens à l'identique.",
            user: source, schema: FicheWriter.contentSchema, model: settings.effectiveAttributionModel(), maxTokens: 6000)
        let (translated, u) = try await provider.generate(request, as: FicheContent.self)
        stats.usage += u
        try store.saveTranslation(ficheId: ficheId, content: translated, language: language)
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
                createdAt: Date(), updatedAt: Date(), readAt: nil, readState: .new, changeNote: nil,
                translation: nil, translationLanguage: nil, review: nil, model: writer.modelLabel)
            try store.saveFiche(restored, threadIds: [])
            try store.detachThreads(threadIds, to: originalId)
        }
        var usage = LLMUsage()
        try await regenerate(ficheId: ficheId, usage: &usage)
        stats.usage += usage
    }
}
