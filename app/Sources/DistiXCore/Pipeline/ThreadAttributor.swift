import Foundation

/// Étape 3 : attribution des nouveaux messages aux fils, par fenêtres chronologiques.
struct ThreadAttributor {
    let store: Store
    let provider: LLMProvider
    let settings: AppSettings

    struct Output: Decodable {
        struct Assignment: Decodable { let message: String; let thread: String }
        struct NewThread: Decodable { let id: String; let summary: String }
        let assignments: [Assignment]
        let new_threads: [NewThread]
    }

    static let schema = Schema.object([
        "assignments": Schema.array(Schema.object(["message": Schema.string, "thread": Schema.string])),
        "new_threads": Schema.array(Schema.object(["id": Schema.string, "summary": Schema.string])),
    ])

    /// Traite une fenêtre. Renvoie false s'il n'y avait plus rien à traiter.
    func processWindow(conversationId: String, pseudo: Pseudonymizer, focus: String? = nil,
                       usage: inout LLMUsage) async throws -> Bool {
        let pending = try store.pendingMessages(in: conversationId, limit: settings.windowSize)
        guard let first = pending.first else { return false }
        let context = try store.contextMessages(in: conversationId, before: first.sentAt, limit: settings.windowOverlap)
        let open = try store.openThreads(in: conversationId, reference: first.sentAt, openDays: settings.threadOpenDays)
        let fmt = MessageFormatter(pseudo: pseudo, maxChars: 1200)

        // Identifiants courts pour le prompt.
        var keyOf: [String: String] = [:]          // sourceId -> clé courte
        var messageOfKey: [String: MessageRecord] = [:]
        for (i, m) in context.enumerated() { keyOf[m.sourceId] = "c\(i + 1)" }
        for (i, m) in pending.enumerated() {
            keyOf[m.sourceId] = "m\(i + 1)"
            messageOfKey["m\(i + 1)"] = m
        }
        var threadOfKey: [String: Int64] = [:]
        for t in open { threadOfKey["T\(t.id!)"] = t.id! }
        let contextThreads = try store.threadIds(forMessages: context.compactMap(\.id))

        // Messages cités hors fenêtre : on retrouve leur fil pour les forcer.
        let replyTargets = Set(pending.compactMap(\.replyToSourceId))
        let cited = try store.messages(sourceIds: Array(replyTargets), in: conversationId)
        let citedThreads = try store.threadIds(forMessages: cited.compactMap(\.id))
        var threadOfSource: [String: Int64] = [:]
        for m in cited { if let t = citedThreads[m.id!] { threadOfSource[m.sourceId] = t } }

        var prompt = ""
        if let focus, !focus.isEmpty {
            prompt += "CONSIGNES DE L'UTILISATEUR POUR CE GROUPE (prioritaires sur les règles générales pour décider ce qui mérite un fil)\n\(focus)\n\n"
        }
        prompt += "FILS OUVERTS\n"
        if open.isEmpty { prompt += "(aucun)\n" }
        for t in open {
            prompt += "[T\(t.id!)] dernier message \(MessageFormatter.dateFormat.string(from: t.lastMessageAt)) — \(t.summary)\n"
            for m in try store.threadMessages(t.id!, last: 3) {
                prompt += "    \(pseudo.name(of: m.authorId)) : \(fmt.body(m).prefix(200))\n"
            }
        }
        prompt += "\nCONTEXTE (déjà classés, ne pas reclasser)\n"
        if context.isEmpty { prompt += "(aucun)\n" }
        for m in context {
            let thread = contextThreads[m.id!].map { "fil T\($0)" } ?? "aucun fil"
            prompt += fmt.line(m, key: keyOf[m.sourceId]!, replyKey: m.replyToSourceId.flatMap { keyOf[$0] }, extra: thread) + "\n"
        }
        prompt += "\nMESSAGES À CLASSER\n"
        for m in pending {
            var reply = m.replyToSourceId.flatMap { keyOf[$0] }
            if reply == nil, let src = m.replyToSourceId, let t = threadOfSource[src] { reply = "un message du fil T\(t)" }
            prompt += fmt.line(m, key: keyOf[m.sourceId]!, replyKey: reply) + "\n"
        }

        let request = LLMRequest(system: CoreResources.prompt("attribution"), user: prompt, schema: Self.schema,
                                 model: settings.effectiveAttributionModel(), maxTokens: 8000)
        let (out, u) = try await provider.generate(request, as: Output.self)
        usage += u

        let newSummaries = Dictionary(out.new_threads.map { ($0.id, $0.summary) }, uniquingKeysWith: { a, _ in a })
        var decided: [String: Store.Assignment.Target] = [:]
        for a in out.assignments where messageOfKey[a.message] != nil {
            if let t = threadOfKey[a.thread] {
                decided[a.message] = .existing(t)
            } else if newSummaries[a.thread] != nil || a.thread.hasPrefix("N") {
                decided[a.message] = .new(key: a.thread)
            } else {
                decided[a.message] = Store.Assignment.Target.none
            }
        }

        // Un lien « réponse à » explicite prime sur l'avis du modèle (brief § 6.2).
        var assignments: [Store.Assignment] = []
        var targetOfSource: [String: Store.Assignment.Target] = [:]
        for (i, m) in pending.enumerated() {
            let key = "m\(i + 1)"
            var target = decided[key] ?? Store.Assignment.Target.none
            if let src = m.replyToSourceId {
                let contextThread = context.first { $0.sourceId == src }.flatMap { contextThreads[$0.id!] }
                if let t = threadOfSource[src] ?? contextThread {
                    target = .existing(t)
                } else if let earlier = targetOfSource[src], !earlier.isNone {
                    target = earlier
                }
            }
            targetOfSource[m.sourceId] = target
            assignments.append(Store.Assignment(messageId: m.id!, target: target))
        }
        try store.applyAttribution(conversationId: conversationId, assignments: assignments, newThreads: newSummaries)
        return true
    }
}

extension Store.Assignment.Target {
    var isNone: Bool { if case .none = self { return true } else { return false } }
}
