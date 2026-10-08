import Foundation

/// Étape 4 : rédaction (ou régénération) d'une fiche à partir de ses fils.
struct FicheWriter {
    let store: Store
    let provider: LLMProvider
    let settings: AppSettings

    struct Output: Decodable {
        struct Answer: Decodable { let summary: String; let support: String; let source_message_ids: [String] }
        let is_knowledge: Bool
        let skip_reason: String
        let question: String
        let context: String
        let status: String
        let theme: String
        let answers: [Answer]
        let disagreements: [String]
        let open_points: [String]
        let links: [String]
        let material_change: Bool
        let change_note: String
        let thread_summary: String
    }

    static let schema = Schema.object([
        "is_knowledge": Schema.boolean,
        "skip_reason": Schema.string,
        "question": Schema.string,
        "context": Schema.string,
        "status": Schema.enumeration(FicheStatus.allCases.map(\.rawValue)),
        "theme": Schema.string,
        "answers": Schema.array(Schema.object([
            "summary": Schema.string,
            "support": Schema.enumeration(["consensus", "avis_isole", "conteste"]),
            "source_message_ids": Schema.array(Schema.string),
        ])),
        "disagreements": Schema.array(Schema.string),
        "open_points": Schema.array(Schema.string),
        "links": Schema.array(Schema.string),
        "material_change": Schema.boolean,
        "change_note": Schema.string,
        "thread_summary": Schema.string,
    ])

    /// Schéma d'une fiche (FicheContent), pour la traduction.
    static let contentSchema = Schema.object([
        "question": Schema.string, "context": Schema.string,
        "status": Schema.enumeration(FicheStatus.allCases.map(\.rawValue)), "theme": Schema.string,
        "answers": Schema.array(Schema.object([
            "summary": Schema.string,
            "support": Schema.enumeration(["consensus", "avis_isole", "conteste"]),
            "source_message_ids": Schema.array(Schema.string),
        ])),
        "disagreements": Schema.array(Schema.string), "open_points": Schema.array(Schema.string),
        "links": Schema.array(Schema.string),
    ])

    /// Un fil très long est tronqué : début (la question) et fin (les dernières réponses).
    static let maxMessages = 160

    struct Result {
        var content: FicheContent?
        var skipReason: String?
        var materialChange: Bool
        var changeNote: String
        var threadSummary: String
    }

    var modelOverride: String? = nil

    var modelLabel: String { "\(provider.displayName) · \(modelOverride ?? settings.effectiveFicheModel())" }

    func write(conversationId: String, threadIds: [Int64], previous: FicheContent?,
               pseudo: Pseudonymizer, usage: inout LLMUsage) async throws -> Result {
        let conversation = try store.conversation(conversationId)
        let focus = conversation?.focus
        let language = conversation?.ficheLanguage(default: settings.ficheLanguage) ?? settings.ficheLanguage
        var messages = try store.messages(ofThreads: threadIds)
        if messages.count > Self.maxMessages {
            messages = Array(messages.prefix(30)) + Array(messages.suffix(Self.maxMessages - 30))
        }
        let fmt = MessageFormatter(pseudo: pseudo, maxChars: 3000)
        var keyOf: [String: String] = [:]
        var sourceOfKey: [String: String] = [:]
        for (i, m) in messages.enumerated() {
            keyOf[m.sourceId] = "m\(i + 1)"
            sourceOfKey["m\(i + 1)"] = m.sourceId
        }
        let themeRecords = try store.themes(in: conversationId)
        let themes = themeRecords.map { t in t.objective.map { "\(t.name) (objectif : \($0))" } ?? t.name }
        var prompt = ""
        if let focus, !focus.isEmpty {
            prompt += "CONSIGNES DE L'UTILISATEUR POUR CE GROUPE (ce qui l'intéresse ; elles priment pour décider is_knowledge et ce que la fiche met en avant)\n\(focus)\n\n"
        }
        prompt += FicheLanguage.instruction(language, messages: messages.compactMap(\.text)) + "\n\n"
        prompt += "THÈMES EXISTANTS : " + (themes.isEmpty ? "(aucun, propose-en un)" : themes.joined(separator: " ; ")) + "\n"
        if themeRecords.contains(where: { $0.objective != nil }) {
            prompt += "Un thème avec un objectif a été défini par l'utilisateur : classe-y la fiche quand elle sert cet objectif, "
                + "et mets en avant dans la fiche ce qui le sert. Pour `theme`, renvoie le nom du thème seul, sans l'objectif.\n"
        }
        prompt += "\n"
        if let previous {
            // La version précédente référence des identifiants source : on les traduit.
            var p = previous
            p.answers = p.answers.map { a in
                var a = a
                a.sourceMessageIds = a.sourceMessageIds.compactMap { keyOf[$0] }
                return a
            }
            prompt += "VERSION PRÉCÉDENTE DE LA FICHE\n" + (String(data: try JSONEncoder.distix.encode(p), encoding: .utf8) ?? "") + "\n\n"
        }
        prompt += "MESSAGES DU FIL\n"
        for m in messages {
            prompt += fmt.line(m, key: keyOf[m.sourceId]!, replyKey: m.replyToSourceId.flatMap { keyOf[$0] }) + "\n"
        }

        let request = LLMRequest(system: CoreResources.prompt("fiche"), user: prompt, schema: Self.schema,
                                 model: modelOverride ?? settings.effectiveFicheModel(), maxTokens: 6000)
        let (out, u) = try await provider.generate(request, as: Output.self)
        usage += u
        guard out.is_knowledge, !out.question.trimmingCharacters(in: .whitespaces).isEmpty else {
            let reason = out.is_knowledge ? "question vide" : (out.skip_reason.isEmpty ? "non précisé" : out.skip_reason)
            return Result(content: nil, skipReason: reason, materialChange: false, changeNote: "",
                          threadSummary: out.thread_summary)
        }
        // Ne rien inventer : une réponse sans message source valide est écartée.
        let answers: [FicheAnswer] = out.answers.compactMap { a in
            let ids = a.source_message_ids.compactMap { sourceOfKey[$0] }
            guard !ids.isEmpty else { return nil }
            return FicheAnswer(summary: a.summary, support: FicheAnswer.Support(rawValue: a.support) ?? .avis_isole,
                               sourceMessageIds: ids)
        }
        var status = FicheStatus(rawValue: out.status) ?? .repondue
        if answers.isEmpty { status = .sans_reponse }
        let content = FicheContent(question: out.question, context: out.context, status: status,
                                   theme: Self.cleanTheme(out.theme), answers: answers,
                                   disagreements: out.disagreements, openPoints: out.open_points,
                                   links: Self.verifiedLinks(out.links, in: messages))
        return Result(content: content, skipReason: nil, materialChange: out.material_change, changeNote: out.change_note,
                      threadSummary: out.thread_summary)
    }
}

extension FicheWriter {
    /// Le modèle recopie parfois l'objectif du thème avec son nom : on ne garde que le nom.
    static func cleanTheme(_ raw: String) -> String {
        let name = raw.components(separatedBy: " (objectif").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Divers" : name
    }

    /// Seuls les liens réellement présents dans les messages sont conservés.
    static func verifiedLinks(_ links: [String], in messages: [MessageRecord]) -> [String] {
        let text = messages.compactMap(\.text).joined(separator: "\n")
        return Array(Set(links.filter { !$0.isEmpty && text.contains($0) })).sorted()
    }
}

/// Étape 5 : confirmation d'une fusion par le modèle.
struct MergeJudge {
    let provider: LLMProvider
    let settings: AppSettings

    struct Output: Decodable { let same_subject: Bool; let reason: String }
    static let schema = Schema.object(["same_subject": Schema.boolean, "reason": Schema.string])

    func sameSubject(_ a: FicheContent, _ b: FicheContent, usage: inout LLMUsage) async throws -> Bool {
        let prompt = """
            FICHE A
            Question : \(a.question)
            Contexte : \(a.context)

            FICHE B
            Question : \(b.question)
            Contexte : \(b.context)
            """
        let (out, u) = try await provider.generate(
            LLMRequest(system: CoreResources.prompt("fusion"), user: prompt, schema: Self.schema,
                       model: settings.effectiveAttributionModel(), maxTokens: 1000), as: Output.self)
        usage += u
        return out.same_subject
    }
}
