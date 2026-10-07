import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claudeCode, anthropic, openAICompatible
}

/// Réglages de l'app, dans UserDefaults (sans les clés, qui sont dans le Trousseau).
public struct AppSettings: Codable, Equatable, Sendable {
    // IA
    public var provider: ProviderKind = .claudeCode
    public var attributionModel = ""
    public var ficheModel = ""
    public var openAIBaseURL = "http://localhost:11434/v1"
    public var claudePath = ""
    // Synchronisation
    public var syncIntervalHours = 3.0
    public var openWhatsAppBeforeSync = false
    public var notificationsEnabled = false
    public var launchAtLogin = false
    // Confidentialité
    public var pseudonymize = true
    public var showRealNames = false
    // Pipeline (valeurs de départ du brief, à ajuster)
    public var windowSize = 80
    public var windowOverlap = 15
    public var threadOpenDays = 7
    public var mergeThreshold = 0.80
    public var crossGroupMerge = false
    /// Fiches rédigées en parallèle.
    public var concurrency = 3
    /// Langue des fiches par défaut ; vide = langue d'origine de la conversation.
    public var ficheLanguage = FicheLanguage.original
    // État
    public var onboardingDone = false

    public init() {}

    public func effectiveAttributionModel() -> String {
        attributionModel.isEmpty ? Self.defaultModels(provider).attribution : attributionModel
    }

    public func effectiveFicheModel() -> String {
        ficheModel.isEmpty ? Self.defaultModels(provider).fiche : ficheModel
    }

    /// Petit modèle rapide pour l'attribution, plus capable pour les fiches.
    public static func defaultModels(_ kind: ProviderKind) -> (attribution: String, fiche: String) {
        switch kind {
        case .claudeCode: return ("haiku", "sonnet")
        case .anthropic: return ("claude-haiku-4-5", "claude-sonnet-5")
        case .openAICompatible: return ("qwen3:8b", "qwen3:14b")
        }
    }

    static let key = "DistiXSettings"

    /// Réglages partagés entre l'app et distix-cli. Le CLI livré dans l'app a le même
    /// identifiant de bundle : il lit alors les réglages standard.
    public static var sharedDefaults: UserDefaults {
        Bundle.main.bundleIdentifier == "com.xavierkain.distix"
            ? .standard : (UserDefaults(suiteName: "com.xavierkain.distix") ?? .standard)
    }

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Décodage tolérant : une clé ajoutée plus tard garde sa valeur par défaut.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        provider = v(.provider, provider); attributionModel = v(.attributionModel, attributionModel)
        ficheModel = v(.ficheModel, ficheModel); openAIBaseURL = v(.openAIBaseURL, openAIBaseURL)
        claudePath = v(.claudePath, claudePath); syncIntervalHours = v(.syncIntervalHours, syncIntervalHours)
        openWhatsAppBeforeSync = v(.openWhatsAppBeforeSync, openWhatsAppBeforeSync)
        notificationsEnabled = v(.notificationsEnabled, notificationsEnabled)
        launchAtLogin = v(.launchAtLogin, launchAtLogin); pseudonymize = v(.pseudonymize, pseudonymize)
        showRealNames = v(.showRealNames, showRealNames); windowSize = v(.windowSize, windowSize)
        windowOverlap = v(.windowOverlap, windowOverlap); threadOpenDays = v(.threadOpenDays, threadOpenDays)
        mergeThreshold = v(.mergeThreshold, mergeThreshold); crossGroupMerge = v(.crossGroupMerge, crossGroupMerge)
        concurrency = v(.concurrency, concurrency); ficheLanguage = v(.ficheLanguage, ficheLanguage)
        onboardingDone = v(.onboardingDone, onboardingDone)
    }
}

public enum ProviderFactory {
    public static let anthropicKeyAccount = "anthropic"
    public static let openAIKeyAccount = "openai-compatible"

    public static func make(_ s: AppSettings) throws -> LLMProvider {
        switch s.provider {
        case .claudeCode:
            guard let exe = ClaudeCodeProvider.locate(custom: s.claudePath) else {
                throw LLMError.notConfigured(String(localized: "Claude Code est introuvable sur ce Mac.", bundle: CoreResources.bundle))
            }
            return ClaudeCodeProvider(executable: exe)
        case .anthropic:
            guard let key = Keychain.get(anthropicKeyAccount), !key.isEmpty else {
                throw LLMError.notConfigured(String(localized: "clé API Anthropic absente", bundle: CoreResources.bundle))
            }
            return AnthropicProvider(apiKey: key)
        case .openAICompatible:
            guard let url = URL(string: s.openAIBaseURL) else {
                throw LLMError.notConfigured(String(localized: "adresse du serveur invalide", bundle: CoreResources.bundle))
            }
            return OpenAICompatibleProvider(baseURL: url, apiKey: Keychain.get(openAIKeyAccount))
        }
    }
}
