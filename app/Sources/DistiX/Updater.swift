import Foundation
import Observation
import Sparkle

/// Mises à jour automatiques, par Sparkle (même dispositif que QuiX et InFlow).
///
/// Sparkle vérifie le flux une fois par jour (`SUScheduledCheckInterval`), affiche les notes
/// de version, télécharge, vérifie la signature EdDSA de l'archive contre `SUPublicEDKey`
/// (Info.plist), installe et relance. La clé privée ne vit que dans le trousseau de Xavier
/// et dans le secret SPARKLE_PRIVATE_KEY de la CI : voir docs/UPDATES.md.
///
/// Sans clé publique dans l'Info.plist (constructions locales de développement), le
/// dispositif est désactivé plutôt que de produire des erreurs à chaque vérification.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let key, !key.isEmpty, Bundle.main.bundleURL.pathExtension == "app" {
            let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            controller = c
            checksAutomatically = c.updater.automaticallyChecksForUpdates
        } else {
            controller = nil
            checksAutomatically = false
        }
    }

    func checkNow() { controller?.updater.checkForUpdates() }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
