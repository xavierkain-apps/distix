import Foundation

/// Tout serveur compatible avec l'API OpenAI « chat completions » : Ollama
/// (http://localhost:11434/v1), LM Studio (http://localhost:1234/v1), ou un service distant.
public struct OpenAICompatibleProvider: LLMProvider {
    public let baseURL: URL
    public let apiKey: String?
    public var displayName: String { "Compatible OpenAI (\(baseURL.host ?? ""))" }
    let session: URLSession

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.session = session
    }

    public func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage) {
        let system = request.system + "\n\nRéponds uniquement avec un objet JSON conforme à ce schéma :\n"
            + request.schema.jsonString
        let body: JSONValue = .object([
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "temperature": .number(0.2),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(request.user)]),
            ]),
            "response_format": .object([
                "type": .string("json_schema"),
                "json_schema": .object(["name": .string("reponse"), "schema": request.schema, "strict": .bool(true)]),
            ]),
        ])
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw LLMError.http(code, String(data: data, encoding: .utf8)?.prefix(300).description ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else { throw LLMError.invalidOutput("aucun choix") }
        if choice.finish_reason == "length" { throw LLMError.truncated }
        guard let json = extractJSON(choice.message.content ?? "") else { throw LLMError.invalidOutput("aucun JSON") }
        return (json, LLMUsage(inputTokens: decoded.usage?.prompt_tokens ?? 0,
                               outputTokens: decoded.usage?.completion_tokens ?? 0, costUSD: 0))
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }
}
