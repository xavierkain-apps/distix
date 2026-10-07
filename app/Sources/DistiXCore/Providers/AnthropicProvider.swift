import Foundation

/// API Anthropic (Messages), clé fournie par l'utilisateur. Requêtes HTTP directes :
/// il n'existe pas de SDK officiel Swift.
public struct AnthropicProvider: LLMProvider {
    public let apiKey: String
    public var displayName: String { "Anthropic API" }
    let session: URLSession
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage) {
        guard !apiKey.isEmpty else { throw LLMError.notConfigured("clé API manquante") }
        let body: JSONValue = .object([
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "system": .string(request.system),
            "messages": .array([.object(["role": .string("user"), "content": .string(request.user)])]),
            "output_config": .object(["format": .object(["type": .string("json_schema"), "schema": request.schema])]),
        ])
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? "HTTP \(code)"
            throw LLMError.http(code, message)
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        switch decoded.stop_reason {
        case "refusal": throw LLMError.refused
        case "max_tokens": throw LLMError.truncated
        default: break
        }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard let json = extractJSON(text) else { throw LLMError.invalidOutput("aucun JSON") }
        let usage = LLMUsage(inputTokens: decoded.usage.input_tokens, outputTokens: decoded.usage.output_tokens,
                             costUSD: Pricing.cost(model: request.model, input: decoded.usage.input_tokens,
                                                   output: decoded.usage.output_tokens))
        return (json, usage)
    }

    struct MessageResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        let content: [Block]
        let stop_reason: String?
        let usage: Usage
    }

    struct ErrorBody: Decodable {
        struct E: Decodable { let message: String }
        let error: E
    }
}
