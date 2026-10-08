import Foundation

/// Export Markdown : une fiche (presse-papiers ou fichier) ou un dossier de fiches
/// rangées par thème, avec un en-tête simple pour Notion ou Obsidian (brief § 7.5).
public struct MarkdownExporter {
    let store: Store
    let showRealNames: Bool

    public init(store: Store, showRealNames: Bool) {
        self.store = store; self.showRealNames = showRealNames
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func statusLabel(_ s: FicheStatus) -> String {
        switch s {
        case .repondue: return String(localized: "Répondue", bundle: CoreResources.bundle)
        case .debattue: return String(localized: "Débattue", bundle: CoreResources.bundle)
        case .sans_reponse: return String(localized: "Sans réponse", bundle: CoreResources.bundle)
        }
    }

    public static func supportLabel(_ s: FicheAnswer.Support) -> String {
        switch s {
        case .consensus: return String(localized: "consensus", bundle: CoreResources.bundle)
        case .avis_isole: return String(localized: "avis isolé", bundle: CoreResources.bundle)
        case .conteste: return String(localized: "contesté", bundle: CoreResources.bundle)
        }
    }

    public func markdown(for fiche: FicheRecord, includeSources: Bool = false) throws -> String {
        guard let c = fiche.decoded else { return "# \(fiche.question)\n" }
        let theme = try store.themeName(fiche.themeId) ?? c.theme
        let group = try store.conversation(fiche.conversationId)?.name ?? ""
        func yaml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var md = """
            ---
            title: \(yaml(c.question))
            theme: \(yaml(theme))
            groupe: \(yaml(group))
            statut: \(Self.statusLabel(c.status))
            premier_message: \(Self.day.string(from: fiche.firstMessageAt))
            dernier_message: \(Self.day.string(from: fiche.lastMessageAt))
            mise_a_jour: \(Self.day.string(from: fiche.updatedAt))
            ---

            # \(c.question)

            """
        if !c.context.isEmpty { md += "\n**Contexte.** \(c.context)\n" }
        if !c.answers.isEmpty {
            md += "\n## " + String(localized: "Réponses", bundle: CoreResources.bundle) + "\n\n"
            for a in c.answers { md += "- \(a.summary) _(\(Self.supportLabel(a.support)))_\n" }
        }
        if !c.disagreements.isEmpty {
            md += "\n## " + String(localized: "Désaccords", bundle: CoreResources.bundle) + "\n\n"
            for d in c.disagreements { md += "- \(d)\n" }
        }
        if !c.openPoints.isEmpty {
            md += "\n## " + String(localized: "Points ouverts", bundle: CoreResources.bundle) + "\n\n"
            for d in c.openPoints { md += "- \(d)\n" }
        }
        if !c.links.isEmpty {
            md += "\n## " + String(localized: "Liens", bundle: CoreResources.bundle) + "\n\n"
            for l in c.links { md += "- <\(LinkCleaner.clean(l))>\n" }
        }
        if includeSources {
            md += "\n## " + String(localized: "Messages sources", bundle: CoreResources.bundle) + "\n\n"
            md += try sourcesMarkdown(for: fiche)
        }
        return md
    }

    public func sourcesMarkdown(for fiche: FicheRecord) throws -> String {
        let messages = try store.messages(ofFiche: fiche.id)
        var authors: [Int64: AuthorRecord] = [:]
        for c in Set(messages.map(\.conversationId)) { authors.merge(try store.authors(in: c)) { a, _ in a } }
        let pseudo = Pseudonymizer(authors: authors, enabled: !showRealNames)
        let fmt = MessageFormatter(pseudo: pseudo, maxChars: 100_000)
        return messages.map { m in
            "> **\(pseudo.name(of: m.authorId))** — \(MessageFormatter.dateFormat.string(from: m.sentAt))  \n> "
                + fmt.body(m).replacingOccurrences(of: " ⏎ ", with: "  \n> ") + "\n"
        }.joined(separator: "\n")
    }

    /// Exporte des fiches dans `folder/<groupe>/<thème>/<question>.md`. Renvoie le nombre de fichiers.
    @discardableResult
    public func export(_ fiches: [FicheRecord], to folder: URL, includeSources: Bool) throws -> Int {
        let fm = FileManager.default
        var count = 0
        for f in fiches {
            let group = Self.safeName(try store.conversation(f.conversationId)?.name ?? "Groupe")
            let theme = Self.safeName(try store.themeName(f.themeId) ?? "Divers")
            let dir = folder.appendingPathComponent(group).appendingPathComponent(theme)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var name = Self.safeName(f.question)
            if fm.fileExists(atPath: dir.appendingPathComponent("\(name).md").path) { name += " (\(f.id.prefix(6)))" }
            try markdown(for: f, includeSources: includeSources)
                .write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            count += 1
        }
        return count
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Sans titre" : cleaned).prefix(90))
    }
}
