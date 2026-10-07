import Foundation
import GRDB

public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "conversations"
    /// "<source>:<identifiant source>"
    public var id: String
    public var source: String
    public var sourceId: String
    public var name: String
    public var selected: Bool
    public var messageCount: Int
    public var lastMessageAt: Date?
    /// Ne traiter que les messages envoyés après cette date (profondeur d'historique).
    public var historyStart: Date?
    public var cursorSequence: Int64?
    public var cursorDate: Date?
    public var lastSyncedAt: Date?
    /// Fréquence propre au groupe, en heures ; nil = réglage global.
    public var syncIntervalHours: Double?
    public var mode: GroupMode = .knowledge
    /// Consignes de l'utilisateur pour ce groupe (centres d'intérêt, critères de veille).
    public var focus: String?
    /// Langue des fiches de ce groupe ; nil = réglage global, "" = langue d'origine.
    public var language: String?

    public func ficheLanguage(default global: String) -> String { language ?? global }

    /// Le groupe doit-il être synchronisé maintenant ?
    public func isDue(globalIntervalHours: Double, now: Date = Date()) -> Bool {
        guard let last = lastSyncedAt else { return true }
        return now.timeIntervalSince(last) >= (syncIntervalHours ?? globalIntervalHours) * 3600 - 30
    }

    public static func makeId(source: String, sourceId: String) -> String { "\(source):\(sourceId)" }
}

/// Ce que l'utilisateur attend d'un groupe.
public enum GroupMode: String, Codable, CaseIterable, Sendable {
    /// Fiches questions-réponses classées par thème.
    case knowledge
    /// Seuls les messages qui correspondent aux critères de l'utilisateur, en opportunités.
    case watch
}

/// Message repéré en mode veille.
public struct OpportunityRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "opportunities"
    public var id: Int64?
    public var conversationId: String
    public var messageId: Int64
    /// Adéquation aux critères, de 0 à 100.
    public var score: Int
    /// Ce que la personne propose ou cherche, en une phrase.
    public var summary: String
    /// Pourquoi cela correspond (ou ce qui coince).
    public var reason: String
    public var sentAt: Date
    public var createdAt: Date
    public var readAt: Date?

    public var isUnread: Bool { readAt == nil }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct AuthorRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "authors"
    public var id: Int64?
    public var conversationId: String
    public var sourceAuthorId: String
    public var displayName: String?
    /// Numéro d'alias stable dans la conversation : « Membre 12 ».
    public var aliasNumber: Int
    public var mentionToken: String?
    /// Numéro pour un contact privé ; local uniquement.
    public var phone: String?

    public var alias: String {
        sourceAuthorId == "me" ? String(localized: "Moi", bundle: CoreResources.bundle)
            : String(localized: "Membre \(aliasNumber)", bundle: CoreResources.bundle)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "messages"
    public var id: Int64?
    public var conversationId: String
    public var sourceId: String
    public var authorId: Int64
    public var sentAt: Date
    public var text: String?
    public var kind: MessageKind
    public var mediaLabel: String?
    public var replyToSourceId: String?
    public var reactionCount: Int
    public var sequence: Int64
    /// Passé par l'étape d'attribution aux fils.
    public var attributed: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ThreadRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "threads"
    public enum State: String, Codable, Sendable { case open, closed }
    public var id: Int64?
    public var conversationId: String
    public var state: State
    public var summary: String
    public var firstMessageAt: Date
    public var lastMessageAt: Date
    /// La fiche doit être (re)générée.
    public var needsFiche: Bool
    /// Raison donnée par le modèle quand le fil n'a pas donné de fiche.
    public var skipReason: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ThreadMessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "thread_messages"
    public var threadId: Int64
    public var messageId: Int64
}

public enum FicheStatus: String, Codable, CaseIterable, Sendable {
    case repondue, debattue, sans_reponse
}

public enum ReadState: String, Codable, Sendable {
    case new, updated
}

public struct FicheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "fiches"
    public var id: String
    public var conversationId: String
    public var themeId: Int64?
    public var status: FicheStatus
    public var question: String
    /// FicheContent encodé en JSON.
    public var content: Data
    public var embedding: Data?
    public var firstMessageAt: Date
    public var lastMessageAt: Date
    public var createdAt: Date
    public var updatedAt: Date
    public var readAt: Date?
    /// Raison de la pastille quand la fiche est non lue.
    public var readState: ReadState?
    public var changeNote: String?
    /// Traduction à la demande (FicheContent en JSON) et sa langue.
    public var translation: Data?
    public var translationLanguage: String?

    public var decoded: FicheContent? { try? JSONDecoder.distix.decode(FicheContent.self, from: content) }
    public var decodedTranslation: FicheContent? {
        translation.flatMap { try? JSONDecoder.distix.decode(FicheContent.self, from: $0) }
    }
    public var isUnread: Bool { readAt == nil }
}

public struct FicheThreadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "fiche_threads"
    public var ficheId: String
    public var threadId: Int64
    public var addedAt: Date
    /// Fiche d'origine quand le fil a été apporté par une fusion (pour la défaire).
    public var mergedFromFicheId: String?
}

public struct ThemeRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "themes"
    public var id: Int64?
    public var conversationId: String
    public var name: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SyncRunRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "sync_runs"
    public var id: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var messagesRead: Int = 0
    public var fichesCreated: Int = 0
    public var fichesUpdated: Int = 0
    public var merges: Int = 0
    public var opportunities: Int = 0
    public var messagesProcessed: Int = 0
    public var threadsSkipped: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var costUSD: Double = 0
    public var error: String?

    public init(startedAt: Date) { self.startedAt = startedAt }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Contenu d'une fiche (schéma du brief § 6.3)

public struct FicheAnswer: Codable, Hashable, Sendable {
    public enum Support: String, Codable, Sendable { case consensus, avis_isole, conteste }
    public var summary: String
    public var support: Support
    /// Identifiants source (stables) des messages qui appuient la réponse.
    public var sourceMessageIds: [String]

    enum CodingKeys: String, CodingKey {
        case summary, support
        case sourceMessageIds = "source_message_ids"
    }
}

public struct FicheContent: Codable, Hashable, Sendable {
    public var question: String
    public var context: String
    public var status: FicheStatus
    public var theme: String
    public var answers: [FicheAnswer]
    public var disagreements: [String]
    public var openPoints: [String]
    public var links: [String]

    enum CodingKeys: String, CodingKey {
        case question, context, status, theme, answers, disagreements, links
        case openPoints = "open_points"
    }

    /// Texte indexé par la recherche.
    var answersText: String {
        (answers.map(\.summary) + disagreements + openPoints).joined(separator: "\n")
    }
}
