import Foundation
import NaturalLanguage

/// Langue de rédaction des fiches. Code vide = langue d'origine de la conversation.
public enum FicheLanguage {
    public static let original = ""
    public static let choices: [(code: String, name: String)] = [
        ("fr", "français"), ("en", "anglais"), ("es", "espagnol"), ("pt", "portugais"),
        ("de", "allemand"), ("it", "italien"), ("nl", "néerlandais"),
    ]

    public static func name(_ code: String) -> String {
        choices.first { $0.code == code }?.name ?? code
    }

    /// Langue majoritaire d'un ensemble de textes (code ISO), détectée sur le Mac.
    public static func detect(_ texts: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue
    }

    /// Nom d'une langue en français (« anglais »), y compris hors de la liste proposée.
    public static func displayName(_ code: String) -> String {
        if let known = choices.first(where: { $0.code == code }) { return known.name }
        return Locale(identifier: "fr_FR").localizedString(forLanguageCode: code)?.lowercased() ?? code
    }

    /// Consigne de langue ajoutée à chaque rédaction. En « langue d'origine », la
    /// langue est détectée localement sur les messages et imposée explicitement :
    /// laisser le modèle la deviner le faisait souvent basculer en français.
    static func instruction(_ code: String, messages: [String]) -> String {
        let target = code.isEmpty ? detect(messages) : code
        guard let target else {
            return "LANGUE DE LA FICHE : la langue majoritaire des messages du fil. Ne traduis pas."
        }
        let name = displayName(target)
        let origin = code.isEmpty ? " (langue des messages : ne traduis pas, même si ces consignes sont en français)" : ""
        return "LANGUE DE LA FICHE : \(name)\(origin). Rédige toute la fiche en \(name), y compris le thème : "
            + "choisis un thème existant rédigé en \(name), sinon propose un nouveau thème en \(name)."
    }
}
