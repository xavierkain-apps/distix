import Foundation

public struct SyncSummary: Sendable, Equatable {
    public var messagesRead = 0
    public var fichesCreated = 0
    public var fichesUpdated = 0
    public var merges = 0
    public var usage = LLMUsage()
    public var error: String?
    public init() {}
}

/// Synchronisation complète : lecture de la source, puis pipeline pour chaque groupe
/// sélectionné. Une seule synchronisation à la fois (brief § 6.6).
public actor SyncEngine {
    let store: Store
    let source: MessageSource
    let embedder: EmbeddingProvider
    let providerOverride: LLMProvider?
    public private(set) var isRunning = false

    public init(store: Store, source: MessageSource, embedder: EmbeddingProvider = NaturalLanguageEmbedder(),
                provider: LLMProvider? = nil) {
        self.store = store; self.source = source; self.embedder = embedder; self.providerOverride = provider
    }

    /// Lit les groupes disponibles dans la source et met à jour la liste locale.
    public func refreshConversations() async throws -> [ConversationRecord] {
        let snap = try await source.snapshot()
        defer { snap.close() }
        try store.upsertConversations(try snap.listConversations(), source: source.id)
        return try store.conversations()
    }

    /// Lance une synchronisation ; renvoie nil si une autre est déjà en cours.
    public func run(settings: AppSettings, only conversationIds: [String]? = nil,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) async -> SyncSummary? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        var summary = SyncSummary()
        var run: SyncRunRecord?
        do {
            run = try store.startRun()
            progress(String(localized: "Lecture de WhatsApp…", bundle: CoreResources.bundle))
            let snap = try await source.snapshot()
            do {
                try store.upsertConversations(try snap.listConversations(), source: source.id)
                for conv in try store.selectedConversations()
                where conversationIds == nil || conversationIds!.contains(conv.id) {
                    let cursor = conv.cursorSequence.map { SyncCursor(sequence: $0, date: conv.cursorDate ?? .distantPast) }
                    let authors = try snap.listAuthors(in: conv.sourceId)
                    let messages = try snap.fetchMessages(in: conv.sourceId, after: cursor, since: conv.historyStart)
                    let newCursor = messages.max { $0.sequence < $1.sequence }
                        .map { SyncCursor(sequence: $0.sequence, date: $0.sentAt) }
                    summary.messagesRead += try store.ingest(conversationId: conv.id, authors: authors,
                                                             messages: messages, cursor: newCursor ?? cursor)
                }
                snap.close()
            } catch {
                snap.close()
                throw error
            }

            let pendingConversations = try store.selectedConversations().filter {
                (conversationIds == nil || conversationIds!.contains($0.id))
            }
            let provider = try providerOverride ?? ProviderFactory.make(settings)
            let pipeline = Pipeline(store: store, provider: provider, embedder: embedder, settings: settings)
            for conv in pendingConversations {
                progress(conv.name)
                do {
                    try await pipeline.process(conversationId: conv.id) { step in progress("\(conv.name) — \(step)") }
                } catch {
                    summary.fichesCreated = pipeline.stats.fichesCreated
                    summary.fichesUpdated = pipeline.stats.fichesUpdated
                    summary.merges = pipeline.stats.merges
                    summary.usage = pipeline.stats.usage
                    throw error
                }
            }
            summary.fichesCreated = pipeline.stats.fichesCreated
            summary.fichesUpdated = pipeline.stats.fichesUpdated
            summary.merges = pipeline.stats.merges
            summary.usage = pipeline.stats.usage
        } catch {
            summary.error = error.localizedDescription
            Log.sync.error("Synchronisation en échec : \(String(describing: type(of: error)), privacy: .public)")
        }
        if var r = run {
            r.finishedAt = Date()
            r.messagesRead = summary.messagesRead
            r.fichesCreated = summary.fichesCreated
            r.fichesUpdated = summary.fichesUpdated
            r.merges = summary.merges
            r.inputTokens = summary.usage.inputTokens
            r.outputTokens = summary.usage.outputTokens
            r.costUSD = summary.usage.costUSD
            r.error = summary.error
            try? store.saveRun(r)
        }
        return summary
    }

    /// Défait les fusions d'une fiche (action de l'interface).
    public func undoMerge(ficheId: String, settings: AppSettings) async throws {
        let provider = try providerOverride ?? ProviderFactory.make(settings)
        try await Pipeline(store: store, provider: provider, embedder: embedder, settings: settings)
            .undoMerge(ficheId: ficheId)
    }
}

/// Estimation du coût et de la durée d'un premier traitement, affichée avant lancement.
public enum CostEstimator {
    public struct Estimate: Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let usd: Double
        public let minutes: Int
    }

    /// Ordres de grandeur par message (à recaler sur les mesures de la phase 1) :
    /// attribution ≈ 120 jetons en entrée et 15 en sortie ; rédaction ≈ 450 et 75.
    public static func estimate(messages: Int, settings: AppSettings) -> Estimate {
        let attIn = messages * 120, attOut = messages * 15
        let ficheIn = messages * 450, ficheOut = messages * 75
        let usd = Pricing.cost(model: settings.effectiveAttributionModel(), input: attIn, output: attOut)
            + Pricing.cost(model: settings.effectiveFicheModel(), input: ficheIn, output: ficheOut)
        // Environ une fenêtre de 80 messages en 30 s, une fiche pour 8 messages en 20 s.
        let seconds = Double(messages) / 80 * 30 + Double(messages) / 8 * 20
        return Estimate(inputTokens: attIn + ficheIn, outputTokens: attOut + ficheOut, usd: usd,
                        minutes: max(1, Int(seconds / 60)))
    }
}
