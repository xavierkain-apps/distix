import Foundation

/// Remplace les noms par des alias stables et masque numéros et e-mails avant tout
/// envoi à un modèle (brief § 6.2, étape 2). La correspondance reste en local
/// (table `authors`).
public struct Pseudonymizer: Sendable {
    let authors: [Int64: AuthorRecord]
    let enabled: Bool
    private let mentionMap: [String: String]

    public init(authors: [Int64: AuthorRecord], enabled: Bool) {
        self.authors = authors
        self.enabled = enabled
        var map: [String: String] = [:]
        for a in authors.values {
            guard let token = a.mentionToken else { continue }
            map[token] = enabled ? a.alias : (a.displayName ?? a.alias)
        }
        mentionMap = map
    }

    public func name(of authorId: Int64) -> String {
        guard let a = authors[authorId] else { return "?" }
        return enabled ? a.alias : (a.displayName ?? a.alias)
    }

    static let mention = try! NSRegularExpression(pattern: "@(\\d{5,})")
    static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    /// Numéros de téléphone (internationaux, et français 0X XX XX XX XX). Volontairement
    /// strict pour ne pas masquer les montants (« 1 250 000 € »).
    static let phones = [
        try! NSRegularExpression(pattern: "(?:\\+|\\b00)\\d{1,3}[\\s.-]?\\(?\\d{1,4}\\)?(?:[\\s.-]?\\d{2,4}){2,5}\\b"),
        try! NSRegularExpression(pattern: "\\b0[1-9](?:[\\s.-]?\\d{2}){4}\\b"),
    ]

    public func clean(_ text: String) -> String {
        var s = Self.replace(Self.mention, in: text) { match in
            let token = String(match.dropFirst())
            if let name = mentionMap[token] { return "@\(name)" }
            return enabled ? "@[membre]" : match
        }
        guard enabled else { return s }
        s = Self.replace(Self.email, in: s) { _ in "[e-mail masqué]" }
        for p in Self.phones { s = Self.replace(p, in: s) { _ in "[numéro masqué]" } }
        return s
    }

    static func replace(_ re: NSRegularExpression, in text: String, with f: (String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Mise en forme d'un message pour un prompt.
struct MessageFormatter {
    let pseudo: Pseudonymizer
    let maxChars: Int

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    func body(_ m: MessageRecord) -> String {
        var parts: [String] = []
        if let label = m.mediaLabel { parts.append("[\(label)]") }
        if let t = m.text, !t.isEmpty {
            let cleaned = pseudo.clean(t).replacingOccurrences(of: "\n", with: " ⏎ ")
            parts.append(cleaned.count > maxChars ? String(cleaned.prefix(maxChars)) + "…" : cleaned)
        }
        return parts.isEmpty ? "[vide]" : parts.joined(separator: " ")
    }

    /// « [m3] 2026-09-12 08:41 · Membre 4 · réponse à m1 · 2 réactions : texte »
    func line(_ m: MessageRecord, key: String, replyKey: String?, extra: String? = nil) -> String {
        var head = "[\(key)] \(Self.dateFormat.string(from: m.sentAt)) · \(pseudo.name(of: m.authorId))"
        if let replyKey { head += " · réponse à \(replyKey)" }
        if m.reactionCount > 0 { head += " · \(m.reactionCount) réaction\(m.reactionCount > 1 ? "s" : "")" }
        if let extra { head += " · \(extra)" }
        return "\(head) : \(body(m))"
    }
}
