import Foundation

/// Chaînes de l'interface, externalisées (fr.lproj/Localizable.strings) pour pouvoir traduire.
enum AppResources {
    static let bundle: Bundle = {
        let name = "DistiX_DistiX.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()
}

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppResources.bundle)
}
