import Foundation

/// Accès aux ressources du module. `Bundle.module` cherche le paquet de ressources à
/// la racine de l'app, ce qui casse la signature ; on regarde d'abord dans
/// Contents/Resources.
public enum CoreResources {
    public static let bundle: Bundle = {
        let name = "DistiX_DistiXCore.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module
    }()

    public static func prompt(_ name: String) -> String {
        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "prompts")
                ?? bundle.url(forResource: name, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Prompt manquant : \(name).md")
        }
        return text
    }
}
