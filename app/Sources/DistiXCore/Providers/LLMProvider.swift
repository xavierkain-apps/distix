import Foundation

public struct LLMRequest: Sendable {
    public var system: String
    public var user: String
    public var schema: JSONValue
    public var model: String
    public var maxTokens: Int

    public init(system: String, user: String, schema: JSONValue, model: String, maxTokens: Int = 8000) {
        self.system = system; self.user = user; self.schema = schema
        self.model = model; self.maxTokens = maxTokens
    }
}

public struct LLMUsage: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    /// Coût facturé (API) ou équivalent tarif API (abonnement), en dollars.
    public var costUSD: Double = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD
    }

    public static func += (l: inout LLMUsage, r: LLMUsage) {
        l.inputTokens += r.inputTokens; l.outputTokens += r.outputTokens; l.costUSD += r.costUSD
    }
}

public enum LLMError: LocalizedError, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case invalidOutput(String)
    case refused
    case truncated
    case process(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return String(localized: "Fournisseur d'IA non configuré : \(s)", bundle: CoreResources.bundle)
        case .http(let code, let s): return String(localized: "Erreur du fournisseur d'IA (\(code)) : \(s)", bundle: CoreResources.bundle)
        case .invalidOutput(let s): return String(localized: "Réponse de l'IA illisible : \(s)", bundle: CoreResources.bundle)
        case .refused: return String(localized: "Le modèle a refusé de répondre.", bundle: CoreResources.bundle)
        case .truncated: return String(localized: "Réponse de l'IA tronquée.", bundle: CoreResources.bundle)
        case .process(let s): return String(localized: "Échec de Claude Code : \(s)", bundle: CoreResources.bundle)
        }
    }

    var isRetryable: Bool {
        switch self {
        case .http(let code, _): return code == 429 || code == 529 || code >= 500
        case .invalidOutput, .truncated: return true
        default: return false
        }
    }
}

/// Fournisseur de génération. Sortie JSON conforme au schéma de la requête.
public protocol LLMProvider: Sendable {
    var displayName: String { get }
    /// Renvoie le JSON brut produit par le modèle.
    func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage)
}

public extension LLMProvider {
    /// Génère et décode, avec nouvelles tentatives sur JSON invalide ou erreur passagère.
    func generate<T: Decodable>(_ request: LLMRequest, as type: T.Type, attempts: Int = 3) async throws -> (T, LLMUsage) {
        var usage = LLMUsage()
        var req = request
        var lastError: Error = LLMError.invalidOutput("aucune tentative")
        for attempt in 0..<attempts {
            do {
                let (data, u) = try await complete(req)
                usage += u
                do {
                    return (try JSONDecoder.distix.decode(T.self, from: data), usage)
                } catch {
                    let detail = String(String(describing: error).prefix(300))
                    lastError = LLMError.invalidOutput(detail)
                    req.user = request.user + "\n\n(Ta réponse précédente ne respectait pas le schéma JSON demandé : "
                        + detail + ". Réponds uniquement avec un JSON valide.)"
                }
            } catch let e as LLMError where e.isRetryable {
                lastError = e
                Log.ai.warning("Tentative \(attempt + 1) échouée : \(e.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt + 1)) * 1_000_000_000))
            }
        }
        throw lastError
    }
}

/// Extrait un objet JSON d'un texte (si le modèle l'entoure de prose ou de ```).
func extractJSON(_ text: String) -> Data? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return String(text[start...end]).data(using: .utf8)
}

// MARK: - Tarifs

public enum Pricing {
    /// Prix en dollars par million de jetons (entrée, sortie). Source : tarifs publics
    /// Anthropic au 2026-10. Les modèles inconnus (locaux) sont gratuits.
    static let table: [String: (Double, Double)] = [
        "claude-haiku-4-5": (1, 5), "haiku": (1, 5),
        "claude-sonnet-5": (2, 10), "sonnet": (2, 10),
        "claude-sonnet-4-6": (3, 15),
        "claude-opus-5": (5, 25), "opus": (5, 25),
        "claude-opus-5-5": (4, 20),
    ]

    public static func cost(model: String, input: Int, output: Int) -> Double {
        let key = table.keys.filter { model.hasPrefix($0) }.max { $0.count < $1.count }
        guard let key, let (i, o) = table[key] else { return 0 }
        return (Double(input) * i + Double(output) * o) / 1_000_000
    }
}
