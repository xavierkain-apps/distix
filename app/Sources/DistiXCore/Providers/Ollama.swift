import Foundation

/// Modèles d'IA locaux via Ollama (https://ollama.com) : rien ne quitte le Mac.
/// DistiX ne télécharge pas Ollama lui-même ; il détecte le service, liste les
/// modèles installés et en télécharge de nouveaux.
public struct OllamaClient: Sendable {
    public let base: URL
    let session: URLSession

    public init(base: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// Adresse compatible OpenAI à utiliser comme fournisseur.
    public var openAIBaseURL: URL { base.appendingPathComponent("v1") }

    public struct Recommended: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let size: String
    }

    /// Modèles conseillés pour rédiger des fiches en français sur un Mac récent.
    public static let recommended: [Recommended] = [
        Recommended(id: "qwen3:8b", label: "Qwen 3 8B — rapide, bon en français", size: "5 Go, 16 Go de mémoire conseillés"),
        Recommended(id: "gemma3:12b", label: "Gemma 3 12B — équilibré", size: "8 Go, 16 Go de mémoire conseillés"),
        Recommended(id: "qwen3:14b", label: "Qwen 3 14B — plus précis", size: "9 Go, 24 Go de mémoire conseillés"),
        Recommended(id: "mistral-small3.2", label: "Mistral Small 3.2 — le plus capable", size: "15 Go, 32 Go de mémoire conseillés"),
    ]

    public func isRunning() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func installedModels() async throws -> [String] {
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let (data, _) = try await session.data(from: base.appendingPathComponent("api/tags"))
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
    }

    /// Télécharge un modèle ; `progress` reçoit une fraction (0…1) et l'étape en cours.
    public func pull(_ model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(["model": model])
        let (bytes, response) = try await session.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "téléchargement refusé")
        }
        struct Event: Decodable { let status: String?; let total: Double?; let completed: Double?; let error: String? }
        for try await line in bytes.lines {
            guard let e = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
            if let error = e.error { throw LLMError.http(500, error) }
            let fraction = (e.total ?? 0) > 0 ? (e.completed ?? 0) / e.total! : 0
            progress(fraction, e.status ?? "")
        }
    }
}
