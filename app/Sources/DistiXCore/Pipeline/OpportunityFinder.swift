import Foundation

/// Mode veille : repère, par fenêtres, les messages qui correspondent aux critères de
/// l'utilisateur. Pas de fils ni de fiches ; un seul appel au petit modèle par fenêtre.
struct OpportunityFinder {
    let store: Store
    let provider: LLMProvider
    let settings: AppSettings

    struct Output: Decodable {
        struct Match: Decodable { let message: String; let score: Int; let summary: String; let reason: String }
        let matches: [Match]
    }

    static let schema = Schema.object([
        "matches": Schema.array(Schema.object([
            "message": Schema.string, "score": Schema.integer, "summary": Schema.string, "reason": Schema.string,
        ])),
    ])

    static let minimumScore = 40

    /// Traite une fenêtre ; renvoie le nombre d'opportunités, ou nil s'il n'y avait plus rien.
    func processWindow(conversationId: String, criteria: String, pseudo: Pseudonymizer,
                       usage: inout LLMUsage) async throws -> Int? {
        let pending = try store.pendingMessages(in: conversationId, limit: settings.windowSize)
        guard let first = pending.first else { return nil }
        let context = try store.contextMessages(in: conversationId, before: first.sentAt, limit: 8)
        let fmt = MessageFormatter(pseudo: pseudo, maxChars: 2000)
        var keyOf: [String: String] = [:]
        var messageOfKey: [String: MessageRecord] = [:]
        for (i, m) in context.enumerated() { keyOf[m.sourceId] = "c\(i + 1)" }
        for (i, m) in pending.enumerated() {
            keyOf[m.sourceId] = "m\(i + 1)"
            messageOfKey["m\(i + 1)"] = m
        }
        var prompt = "CRITÈRES DE L'UTILISATEUR\n\(criteria)\n\nCONTEXTE\n"
        if context.isEmpty { prompt += "(aucun)\n" }
        for m in context { prompt += fmt.line(m, key: keyOf[m.sourceId]!, replyKey: m.replyToSourceId.flatMap { keyOf[$0] }) + "\n" }
        prompt += "\nMESSAGES À EXAMINER\n"
        for m in pending { prompt += fmt.line(m, key: keyOf[m.sourceId]!, replyKey: m.replyToSourceId.flatMap { keyOf[$0] }) + "\n" }

        let request = LLMRequest(system: CoreResources.prompt("veille"), user: prompt, schema: Self.schema,
                                 model: settings.effectiveAttributionModel(), maxTokens: 6000)
        let (out, u) = try await provider.generate(request, as: Output.self)
        usage += u
        var seen = Set<Int64>()
        let found: [OpportunityRecord] = out.matches.compactMap { match in
            guard match.score >= Self.minimumScore, let m = messageOfKey[match.message],
                  m.kind == .text || m.text != nil, seen.insert(m.id!).inserted else { return nil }
            return OpportunityRecord(id: nil, conversationId: conversationId, messageId: m.id!,
                                     score: min(100, max(0, match.score)), summary: match.summary, reason: match.reason,
                                     sentAt: m.sentAt, createdAt: Date(), readAt: nil)
        }
        try store.saveOpportunities(found, markAttributed: pending.compactMap(\.id))
        return found.count
    }
}
