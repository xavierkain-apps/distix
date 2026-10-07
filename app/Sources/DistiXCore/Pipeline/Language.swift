import Foundation

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

    /// Consigne de langue ajoutée à chaque rédaction, pour un résultat stable.
    static func instruction(_ code: String) -> String {
        if code.isEmpty {
            return "LANGUE DE LA FICHE : la langue majoritaire des messages du fil. Ne traduis pas. "
                + "Le thème est dans cette même langue (si aucun thème existant n'est dans cette langue, propose-en un)."
        }
        return "LANGUE DE LA FICHE : \(name(code)). Rédige toute la fiche et le thème en \(name(code)), en traduisant "
            + "si les messages sont dans une autre langue. Choisis ou propose un thème en \(name(code))."
    }
}
