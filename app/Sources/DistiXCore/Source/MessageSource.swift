import Foundation

/// Interface commune aux messageries. Rien en dehors de `Source/` ne connaît WhatsApp.
///
/// Écart assumé avec le brief (§ 6.1) : la lecture passe par un instantané
/// (`SourceSnapshot`), pour ne copier la base qu'une fois par synchronisation.
public protocol MessageSource: Sendable {
    var id: String { get }
    func checkAvailability() async -> SourceStatus
    func snapshot() async throws -> SourceSnapshot
}

public protocol SourceSnapshot: AnyObject {
    func listConversations() throws -> [SourceConversation]
    /// Membres connus d'une conversation (pour les noms et les mentions).
    func listAuthors(in conversationId: String) throws -> [SourceAuthor]
    /// Messages postérieurs au curseur, et envoyés après `since` si fourni,
    /// dans l'ordre d'insertion dans la source.
    func fetchMessages(in conversationId: String, after cursor: SyncCursor?,
                       since: Date?) throws -> [SourceMessage]
    func close()
}

public enum SourceStatus: Equatable, Sendable {
    case available
    case notInstalled
    case permissionDenied(path: String)
    case schemaChanged(missing: [String])
    case unreadable(String)
}

public enum SourceError: LocalizedError, Equatable {
    case notInstalled
    case permissionDenied(path: String)
    case schemaChanged(missing: [String])
    case inconsistentCopy(String)
    case unknownConversation(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "La base de WhatsApp est introuvable. WhatsApp Desktop est-il installé et connecté ?", bundle: CoreResources.bundle)
        case .permissionDenied:
            return String(localized: "macOS refuse l'accès aux données de WhatsApp. Autorisez DistiX dans Réglages Système > Confidentialité et sécurité > Accès complet au disque.", bundle: CoreResources.bundle)
        case .schemaChanged(let missing):
            return String(localized: "WhatsApp a modifié le format de sa base. Synchronisation arrêtée sans rien modifier. Éléments absents : \(missing.joined(separator: ", "))", bundle: CoreResources.bundle)
        case .inconsistentCopy(let detail):
            return String(localized: "Copie de la base WhatsApp incohérente (WhatsApp écrivait pendant la copie). Réessayez dans un instant. \(detail)", bundle: CoreResources.bundle)
        case .unknownConversation(let id):
            return String(localized: "Conversation inconnue : \(id)", bundle: CoreResources.bundle)
        }
    }
}

public struct SourceConversation: Equatable, Sendable {
    public let id: String
    public let name: String
    public let isGroup: Bool
    public let messageCount: Int
    public let firstMessageAt: Date?
    public let lastMessageAt: Date?

    public init(id: String, name: String, isGroup: Bool, messageCount: Int,
                firstMessageAt: Date?, lastMessageAt: Date?) {
        self.id = id; self.name = name; self.isGroup = isGroup
        self.messageCount = messageCount
        self.firstMessageAt = firstMessageAt; self.lastMessageAt = lastMessageAt
    }
}

public struct SourceAuthor: Equatable, Sendable {
    public let id: String
    public let displayName: String?
    /// Forme que prend une mention de cet auteur dans le texte (« 3361234 » pour
    /// « @3361234 »), si la source utilise ce mécanisme.
    public let mentionToken: String?

    public init(id: String, displayName: String?, mentionToken: String?) {
        self.id = id; self.displayName = displayName; self.mentionToken = mentionToken
    }
}

public enum MessageKind: String, Codable, Sendable {
    case text, media, system, deleted
}

public struct SourceMessage: Equatable, Sendable {
    public let sourceId: String
    public let conversationId: String
    public let authorId: String
    public let authorDisplayName: String?
    public let sentAt: Date
    public let text: String?
    public let kind: MessageKind
    /// Marqueur pour un média : « image », « vocal », « document : devis.pdf »…
    public let mediaLabel: String?
    public let replyToSourceId: String?
    public let reactionCount: Int
    /// Ordre d'insertion dans la source : sert de curseur.
    public let sequence: Int64

    public init(sourceId: String, conversationId: String, authorId: String,
                authorDisplayName: String?, sentAt: Date, text: String?, kind: MessageKind,
                mediaLabel: String? = nil, replyToSourceId: String? = nil,
                reactionCount: Int = 0, sequence: Int64) {
        self.sourceId = sourceId; self.conversationId = conversationId
        self.authorId = authorId; self.authorDisplayName = authorDisplayName
        self.sentAt = sentAt; self.text = text; self.kind = kind
        self.mediaLabel = mediaLabel; self.replyToSourceId = replyToSourceId
        self.reactionCount = reactionCount; self.sequence = sequence
    }
}

/// Curseur de synchronisation, par conversation.
///
/// WhatsApp insère tardivement les messages reçus pendant que le Mac était éteint,
/// avec leur date d'envoi d'origine : un curseur fondé sur la date les manquerait.
/// On suit donc l'ordre d'insertion (`sequence`) ; la date sert à l'affichage.
public struct SyncCursor: Codable, Equatable, Sendable {
    public var sequence: Int64
    public var date: Date

    public init(sequence: Int64, date: Date) {
        self.sequence = sequence; self.date = date
    }
}
