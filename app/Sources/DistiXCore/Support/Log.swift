import Foundation
import os

/// Journal de l'app. Règle : jamais de texte de message ni de clé dans les journaux.
public enum Log {
    public static let core = Logger(subsystem: "com.xavierkain.distix", category: "core")
    public static let sync = Logger(subsystem: "com.xavierkain.distix", category: "sync")
    public static let ai = Logger(subsystem: "com.xavierkain.distix", category: "ai")
}
