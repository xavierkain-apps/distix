import Foundation

/// Utilise le CLI `claude` installé sur le Mac, en mode non interactif. La
/// consommation passe par l'abonnement Claude de la personne connectée dans Claude
/// Code (usage personnel). Aucun outil n'est activé, aucune session n'est conservée.
public struct ClaudeCodeProvider: LLMProvider {
    public let executable: URL
    public var displayName: String { "Claude Code" }

    public init(executable: URL) { self.executable = executable }

    /// Emplacements possibles du CLI, du plus probable au moins probable. Une app
    /// lancée depuis le Finder n'a pas le PATH du shell. On cherche aussi le binaire
    /// fourni par l'app Claude (claude-code/<version>[/<hash>]/claude.app), version la
    /// plus récente d'abord, car les lanceurs du PATH peuvent être cassés.
    public static func candidates(custom: String? = nil) -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var paths = [custom].compactMap { $0 }.filter { !$0.isEmpty }
        paths += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let root = URL(fileURLWithPath: "\(home)/Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            let dir = root.appendingPathComponent(v)
            var bases = [dir]
            bases += ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map { dir.appendingPathComponent($0) }
            for base in bases {
                paths.append(base.appendingPathComponent("claude.app/Contents/MacOS/claude").path)
                paths.append(base.appendingPathComponent("claude").path)
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted && fm.isExecutableFile(atPath: $0) && !$0.hasSuffix("/") }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Premier candidat qui fonctionne réellement (`claude --version` réussit) :
    /// un lanceur peut être exécutable mais cassé.
    public static func locate(custom: String? = nil) -> URL? {
        candidates(custom: custom).first { works($0) }
    }

    static func works(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = url
        p.arguments = ["--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    public func complete(_ request: LLMRequest) async throws -> (json: Data, usage: LLMUsage) {
        let args = ["-p", "--output-format", "json", "--model", request.model,
                    "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                    "--no-session-persistence", "--system-prompt", request.system,
                    "--json-schema", request.schema.jsonString]
        let (out, err, status) = try await run(args: args, stdin: request.user)
        guard let result = try? JSONDecoder().decode(CLIResult.self, from: out) else {
            throw LLMError.process("sortie illisible (code \(status)) \(String(data: err, encoding: .utf8)?.prefix(300) ?? "")")
        }
        if result.is_error == true {
            let message = result.result ?? result.subtype ?? "erreur"
            if ["authenticate", "oauth", "/login", "not logged", "log in"].contains(where: { message.localizedCaseInsensitiveContains($0) }) {
                throw LLMError.notConfigured(String(localized: "Claude Code n'est pas connecté à votre compte. Ouvrez Terminal, lancez « \(executable.path) », tapez /login et suivez les instructions, puis réessayez.", bundle: CoreResources.bundle))
            }
            if message.localizedCaseInsensitiveContains("rate") || message.localizedCaseInsensitiveContains("limit") {
                throw LLMError.http(429, message)
            }
            throw LLMError.process(message)
        }
        let json: Data
        if let structured = result.structured_output {
            json = try JSONEncoder().encode(structured)
        } else if let text = result.result, let extracted = extractJSON(text) {
            json = extracted
        } else {
            throw LLMError.invalidOutput("aucun JSON")
        }
        let input = (result.usage?.input_tokens ?? 0) + (result.usage?.cache_read_input_tokens ?? 0)
            + (result.usage?.cache_creation_input_tokens ?? 0)
        return (json, LLMUsage(inputTokens: input, outputTokens: result.usage?.output_tokens ?? 0,
                               costUSD: result.total_cost_usd ?? 0))
    }

    struct CLIResult: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }
        let is_error: Bool?
        let subtype: String?
        let result: String?
        let structured_output: JSONValue?
        let usage: Usage?
        let total_cost_usd: Double?
    }

    private func run(args: [String], stdin: String) async throws -> (Data, Data, Int32) {
        let exe = executable
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                // Dossier vide : aucun CLAUDE.md de projet n'est chargé.
                let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("distix-claude")
                try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                p.currentDirectoryURL = cwd
                var env = ProcessInfo.processInfo.environment
                // Garantit l'usage de l'abonnement : une clé API présente dans
                // l'environnement serait utilisée (et facturée) à sa place. On retire
                // aussi les variables d'une éventuelle session Claude Code parente.
                for key in env.keys where key == "ANTHROPIC_API_KEY" || key == "CLAUDECODE"
                    || (key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDE_CODE_OAUTH_TOKEN") {
                    env.removeValue(forKey: key)
                }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    cont.resume(throwing: LLMError.process("lancement impossible : \(error.localizedDescription)"))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
                let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: timeout)
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timeout.cancel()
                group.wait()
                cont.resume(returning: (outData, errData, p.terminationStatus))
            }
        }
    }
}
