import Foundation
@testable import DistiXCore

/// Fournisseur d'IA factice et déterministe : il lit le prompt et répond selon des
/// règles simples, pour tester la mécanique du pipeline sans réseau.
final class StubLLM: LLMProvider, @unchecked Sendable {
    var displayName: String { "stub" }
    var calls: [String] = []
    var failAfter: Int?
    /// Questions considérées comme identiques par le juge de fusion.
    var sameSubject = true
    var materialChange = true
    private let lock = NSLock()

    func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage) {
        let count: Int = lock.withLock {
            calls.append(request.system.hasPrefix("Tu aides") ? "attribution" : request.system.hasPrefix("Tu rédiges") ? "fiche"
                         : request.system.hasPrefix("Tu fais de la veille") ? "veille" : "fusion")
            return calls.count
        }
        if let failAfter, count > failAfter { throw LLMError.http(400, "panne simulée") }
        let usage = LLMUsage(inputTokens: 100, outputTokens: 10, costUSD: 0.001)
        let user = request.user
        if request.system.hasPrefix("Tu aides") {
            return (try JSONSerialization.data(withJSONObject: attribution(user)), usage)
        } else if request.system.hasPrefix("Tu traduis") {
            return (Data(user.utf8), usage)                       // « traduction » identique
        } else if request.system.hasPrefix("Tu fais de la veille") {
            // Règle : un message contenant « cherche » correspond, score 80.
            let lines = (user.components(separatedBy: "MESSAGES À EXAMINER\n").last ?? "").components(separatedBy: "\n")
            let matches = lines.filter { $0.hasPrefix("[m") && $0.contains("cherche") }.map { line -> [String: Any] in
                ["message": String(line.dropFirst().prefix { $0 != "]" }), "score": 80, "summary": "Besoin", "reason": "Correspond"]
            }
            return (try JSONSerialization.data(withJSONObject: ["matches": matches]), usage)
        } else if request.system.hasPrefix("Tu rédiges") {
            return (try JSONSerialization.data(withJSONObject: fiche(user)), usage)
        } else {
            return (try JSONSerialization.data(withJSONObject: ["same_subject": sameSubject, "reason": "test"]), usage)
        }
    }

    /// Règle : un message contenant « ? » ouvre un nouveau fil ; les autres vont au
    /// dernier fil (ouvert ou créé dans la fenêtre) ; « merci » seul va à « aucun ».
    private func attribution(_ prompt: String) -> [String: Any] {
        var current: String? = prompt.components(separatedBy: "\n").first { $0.hasPrefix("[T") }
            .flatMap { $0.split(separator: "]").first.map { String($0.dropFirst()) } }
        var assignments: [[String: String]] = []
        var newThreads: [[String: String]] = []
        let toClassify = prompt.components(separatedBy: "MESSAGES À CLASSER\n").last ?? ""
        for line in toClassify.components(separatedBy: "\n") where line.hasPrefix("[m") {
            let key = String(line.dropFirst().prefix { $0 != "]" })
            if line.contains("?") {
                let id = "N\(newThreads.count + 1)"
                newThreads.append(["id": id, "summary": "Question \(id)"])
                current = id
                assignments.append(["message": key, "thread": id])
            } else if line.lowercased().contains("merci") || current == nil {
                assignments.append(["message": key, "thread": "aucun"])
            } else {
                assignments.append(["message": key, "thread": current!])
            }
        }
        return ["assignments": assignments, "new_threads": newThreads]
    }

    private func fiche(_ prompt: String) -> [String: Any] {
        let lines = prompt.components(separatedBy: "MESSAGES DU FIL\n").last!.components(separatedBy: "\n").filter { $0.hasPrefix("[m") }
        let question = lines.first.map { String($0.split(separator: ":").dropFirst(2).joined(separator: ":")).trimmingCharacters(in: .whitespaces) } ?? ""
        let answerKeys = lines.dropFirst().map { String($0.dropFirst().prefix { $0 != "]" }) }
        let hasPrevious = prompt.contains("VERSION PRÉCÉDENTE")
        return [
            "is_knowledge": !question.contains("bavardage"), "skip_reason": question.contains("bavardage") ? "bavardage" : "",
            "question": question, "context": "Contexte.",
            "status": answerKeys.isEmpty ? "sans_reponse" : "repondue", "theme": "Financement",
            "answers": answerKeys.isEmpty ? [] : [["summary": "Réponse", "support": "consensus",
                                                   "source_message_ids": answerKeys + ["m999"]]],
            "disagreements": [], "open_points": [], "links": ["https://exemple.fr/invente"],
            "material_change": hasPrevious ? materialChange : true, "change_note": hasPrevious ? "Nouvelle réponse." : "",
            "thread_summary": question,
        ]
    }
}

/// Embeddings factices : même texte de question -> même vecteur.
struct StubEmbedder: EmbeddingProvider {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { NaturalLanguageEmbedder.hashed(String($0.split(separator: "\n").first ?? "")) }
    }
}

/// Enregistre les prompts envoyés, puis délègue.
final class RecordingLLM: LLMProvider, @unchecked Sendable {
    let base: StubLLM
    var prompts: [String] = []
    private let lock = NSLock()
    init(base: StubLLM) { self.base = base; base.sameSubject = false }
    var displayName: String { "recording" }
    func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage) {
        lock.withLock { prompts.append(request.user) }
        return try await base.complete(request)
    }
}
