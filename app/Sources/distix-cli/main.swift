import DistiXCore
import Foundation

// Outil en ligne de commande : mêmes données et même pipeline que l'app.
// Sert aux tests sur le Mac sans passer par l'interface.

let usage = """
    distix-cli [--db chemin] [--wa chemin] <commande>

    Commandes :
      groups                          liste les groupes WhatsApp (noms : local uniquement)
      select "<morceau du nom>" [--since AAAA-MM-JJ]
                                      coche les groupes dont le nom contient ce texte
      unselect "<morceau du nom>"     décoche (sans supprimer les données)
      forget "<morceau du nom>"       décoche et supprime les données locales du groupe
      sync [--provider claudeCode|anthropic|openAICompatible]
                                      synchronise les groupes cochés
      stats                           volumes et coûts, sans aucun contenu
      threads                         fils, résumé et motif de rejet (contenu : local uniquement)
      export <dossier> [--sources]    exporte toutes les fiches en Markdown
      check                           vérifie l'accès à WhatsApp et au fournisseur d'IA
    """

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}
func err(_ message: String) { FileHandle.standardError.write((message + "\n").data(using: .utf8)!) }

let dbPath = option("--db")
let waPath = option("--wa")
let providerName = option("--provider")
let since = option("--since")
let includeSources = flag("--sources")
guard let command = args.first else { fail(usage) }

var settings = AppSettings.load(AppSettings.sharedDefaults)
if let providerName {
    guard let kind = ProviderKind(rawValue: providerName) else { fail("Fournisseur inconnu : \(providerName)") }
    settings.provider = kind
}

do {
    let database = try dbPath.map { try AppDatabase.open(at: URL(fileURLWithPath: $0)) } ?? AppDatabase.openDefault()
    let store = Store(database)
    let source = WhatsAppSource(databaseURL: waPath.map { URL(fileURLWithPath: $0) } ?? WhatsAppSource.defaultDatabaseURL)
    let engine = SyncEngine(store: store, source: source)
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"

    switch command {
    case "groups":
        for c in try await engine.refreshConversations() {
            let last = c.lastMessageAt.map { day.string(from: $0) } ?? "—"
            print("\(c.selected ? "[x]" : "[ ]") \(String(c.messageCount).padding(toLength: 6, withPad: " ", startingAt: 0)) \(last)  \(c.name)")
        }

    case "select", "unselect":
        guard args.count >= 2 else { fail(usage) }
        let needle = args[1].lowercased()
        _ = try await engine.refreshConversations()
        let matches = try store.conversations().filter { $0.name.lowercased().contains(needle) }
        guard !matches.isEmpty else { fail("Aucun groupe ne contient « \(args[1]) ».") }
        let start = since.flatMap { day.date(from: $0) }
        for c in matches {
            try store.setSelected(c.id, selected: command == "select", historyStart: start)
            print("\(command == "select" ? "coché" : "décoché") : \(c.name)")
        }

    case "forget":
        guard args.count >= 2 else { fail(usage) }
        let needle = args[1].lowercased()
        let matches = try store.conversations().filter { $0.name.lowercased().contains(needle) }
        guard !matches.isEmpty else { fail("Aucun groupe ne contient « \(args[1]) ».") }
        for c in matches {
            try store.setSelected(c.id, selected: false, historyStart: nil)
            try store.deleteData(of: c.id)
            print("données supprimées : \(c.name)")
        }

    case "sync":
        let started = Date()
        guard let summary = await engine.run(settings: settings, progress: { err($0) }) else {
            fail("Une synchronisation est déjà en cours.")
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        print("""
            Messages lus dans WhatsApp : \(summary.messagesRead), traités : \(summary.messagesProcessed)
            Fils écartés (pas de fiche) : \(summary.threadsSkipped)
            Fiches créées : \(summary.fichesCreated), mises à jour : \(summary.fichesUpdated), fusions : \(summary.merges)
            Jetons : \(summary.usage.inputTokens) en entrée, \(summary.usage.outputTokens) en sortie
            Coût (ou équivalent tarif API) : \(String(format: "%.3f", summary.usage.costUSD)) $
            Durée : \(elapsed / 60) min \(elapsed % 60) s
            """)
        if let e = summary.error { fail("Erreur : \(e)") }

    case "stats":
        let r = try store.statistics()
        for (k, v) in r.sorted(by: { $0.key < $1.key }) { print("\(k) : \(v)") }
        if let run = try store.lastRun() {
            let end = run.finishedAt.map { " → \($0)" } ?? " (en cours ou interrompue)"
            print("dernière synchro : \(run.startedAt)\(end), jetons \(run.inputTokens)/\(run.outputTokens), \(String(format: "%.3f", run.costUSD)) $\(run.error.map { ", erreur : \($0)" } ?? "")")
        }

    case "export":
        guard args.count >= 2 else { fail(usage) }
        let folder = URL(fileURLWithPath: args[1])
        let n = try MarkdownExporter(store: store, showRealNames: settings.showRealNames)
            .export(try store.fiches(.init()), to: folder, includeSources: includeSources)
        if n == 0 {
            print("Aucune fiche à exporter (voir `distix-cli threads` pour les fils écartés et leur motif).")
        } else {
            print("\(n) fiches exportées dans \(folder.path)")
        }

    case "threads":
        // Contenu local : résumés et motifs de rejet rédigés par le modèle.
        for (t, n, fiche) in try store.threads(in: nil) {
            let state = fiche != nil ? "fiche" : (t.skipReason.map { "écarté : \($0)" } ?? "en attente")
            print("[T\(t.id!)] \(n) msg · \(state)\n    \(t.summary)")
        }

    case "check":
        print("WhatsApp : \(await source.checkAvailability())")
        if settings.provider == .claudeCode {
            let all = ClaudeCodeProvider.candidates(custom: settings.claudePath)
            print("Claude Code : \(all.count) emplacement(s) trouvé(s), retenu : \(ClaudeCodeProvider.locate(custom: settings.claudePath)?.path ?? "aucun qui fonctionne")")
        }
        do {
            let provider = try ProviderFactory.make(settings)
            let schema = Schema.object(["ok": Schema.boolean])
            struct R: Decodable { let ok: Bool }
            let (r, u) = try await provider.generate(LLMRequest(system: "Réponds en JSON.", user: "Renvoie ok = true.",
                                                                schema: schema, model: settings.effectiveAttributionModel(),
                                                                maxTokens: 200), as: R.self)
            print("IA (\(provider.displayName), \(settings.effectiveAttributionModel())) : \(r.ok ? "OK" : "réponse inattendue"), \(u.inputTokens)/\(u.outputTokens) jetons")
        } catch {
            print("IA : échec — \(error.localizedDescription)")
        }

    default:
        fail(usage)
    }
} catch {
    fail("Erreur : \(error.localizedDescription)")
}
