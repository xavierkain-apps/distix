import Foundation
import GRDB

/// Connecteur WhatsApp Desktop (macOS). Seul fichier qui connaît le schéma de
/// `ChatStorage.sqlite` ; référence : docs/schema-whatsapp.md.
///
/// Règles (brief § 4.3) : aucune écriture dans le dossier de WhatsApp ; on copie la
/// base et ses fichiers -wal/-shm, on ouvre la copie en lecture seule, on la supprime.
public struct WhatsAppSource: MessageSource {
    public let id = "whatsapp"
    public let databaseURL: URL

    public static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")

    public init(databaseURL: URL = WhatsAppSource.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    public func checkAvailability() async -> SourceStatus {
        do {
            let snap = try await snapshot()
            snap.close()
            return .available
        } catch SourceError.notInstalled {
            return .notInstalled
        } catch SourceError.permissionDenied(let path) {
            return .permissionDenied(path: path)
        } catch SourceError.schemaChanged(let missing) {
            return .schemaChanged(missing: missing)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func snapshot() async throws -> SourceSnapshot {
        try WhatsAppSnapshot(original: databaseURL)
    }
}

// MARK: - Schéma attendu

enum WhatsAppSchema {
    /// Colonnes sans lesquelles la lecture est impossible ou fausse.
    static let required: [String: [String]] = [
        "ZWACHATSESSION": ["Z_PK", "ZCONTACTJID", "ZPARTNERNAME"],
        "ZWAMESSAGE": ["Z_PK", "ZCHATSESSION", "ZTEXT", "ZMESSAGEDATE", "ZISFROMME",
                       "ZMESSAGETYPE", "ZSTANZAID", "ZGROUPMEMBER", "ZMEDIAITEM"],
        "ZWAGROUPMEMBER": ["Z_PK", "ZCHATSESSION", "ZMEMBERJID"],
        "ZWAMEDIAITEM": ["Z_PK", "ZMETADATA"],
    ]

    static let groupSuffix = "@g.us"

    /// Champ de ZWAMEDIAITEM.ZMETADATA contenant l'identifiant du message cité.
    static let replyIdPath = "5"
    /// Champ de ZWAMESSAGEINFO.ZRECEIPTINFO regroupant les réactions.
    static let reactionsField = "7"

    /// Types sans contenu exploitable : événements de groupe (6), entrées vides de
    /// type 10 (appels ou notifications ; aucun texte ni média constaté), supprimés (14).
    /// Exclus du décompte des groupes affiché à l'utilisateur.
    static let noContentTypes = "6, 10, 14"

    static func kind(of type: Int) -> (MessageKind, String?) {
        switch type {
        case 0, 7: return (.text, nil)
        case 1: return (.media, "image")
        case 2: return (.media, "vidéo")
        case 3: return (.media, "vocal")
        case 4: return (.media, "contact")
        case 5: return (.media, "position")
        case 8: return (.media, "document")
        case 11: return (.media, "gif")
        case 15: return (.media, "sticker")
        case 46: return (.media, "sondage")
        case 6, 10: return (.system, nil)
        case 14: return (.deleted, nil)
        default: return (.media, "contenu")
        }
    }
}

// MARK: - Instantané

final class WhatsAppSnapshot: SourceSnapshot {
    private let directory: URL
    private var dbQueue: DatabaseQueue?
    private var hasProfileNames = false
    private var hasMessageInfo = false
    private var messageInfoByPK = false

    init(original: URL, attempts: Int = 3) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { throw SourceError.notInstalled }
        var lastError = ""
        directory = fm.temporaryDirectory.appendingPathComponent("distix-\(UUID().uuidString)")
        for _ in 0..<attempts {
            try? fm.removeItem(at: directory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(original.lastPathComponent)
            do {
                for suffix in ["", "-wal", "-shm"] {
                    let src = URL(fileURLWithPath: original.path + suffix)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    // copyItem lit la source sans jamais l'ouvrir en écriture.
                    try fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix))
                }
            } catch let error as NSError where Self.isPermissionError(error) {
                try? fm.removeItem(at: directory)
                throw SourceError.permissionDenied(path: original.deletingLastPathComponent().path)
            }
            var config = Configuration()
            config.readonly = true
            config.label = "whatsapp-copy"
            do {
                let queue = try DatabaseQueue(path: copy.path, configuration: config)
                let check = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
                if check == "ok" {
                    dbQueue = queue
                    try validateSchema()
                    return
                }
                lastError = check ?? "?"
            } catch let error as SourceError {
                close()
                throw error
            } catch {
                lastError = String(describing: error)
            }
        }
        close()
        throw SourceError.inconsistentCopy(lastError)
    }

    deinit { close() }

    func close() {
        dbQueue = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           under.domain == NSPOSIXErrorDomain, under.code == Int(EPERM) || under.code == Int(EACCES) {
            return true
        }
        return false
    }

    private func db() throws -> DatabaseQueue {
        guard let q = dbQueue else { throw SourceError.inconsistentCopy("instantané fermé") }
        return q
    }

    private func validateSchema() throws {
        try db().read { db in
            var missing: [String] = []
            for (table, cols) in WhatsAppSchema.required.sorted(by: { $0.key < $1.key }) {
                let have: Set<String> = try db.tableExists(table) ? Set(db.columns(in: table).map(\.name)) : []
                missing += cols.filter { !have.contains($0) }.map { "\(table).\($0)" }
            }
            if !missing.isEmpty { throw SourceError.schemaChanged(missing: missing) }
            func has(_ table: String, _ cols: Set<String>) throws -> Bool {
                guard try db.tableExists(table) else { return false }
                return Set(try db.columns(in: table).map(\.name)).isSuperset(of: cols)
            }
            hasProfileNames = try has("ZWAPROFILEPUSHNAME", ["ZJID", "ZPUSHNAME"])
            hasMessageInfo = try has("ZWAMESSAGEINFO", ["ZMESSAGE", "ZRECEIPTINFO"])
            messageInfoByPK = try db.columns(in: "ZWAMESSAGE").contains { $0.name == "ZMESSAGEINFO" }
        }
    }

    // MARK: Lecture

    func listConversations() throws -> [SourceConversation] {
        try db().read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.ZCONTACTJID AS jid, s.ZPARTNERNAME AS name, COUNT(m.Z_PK) AS n,
                       MIN(m.ZMESSAGEDATE) AS first, MAX(m.ZMESSAGEDATE) AS last
                FROM ZWACHATSESSION s
                LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = s.Z_PK
                    AND m.ZMESSAGETYPE NOT IN (\(WhatsAppSchema.noContentTypes))
                WHERE s.ZCONTACTJID LIKE '%' || ?
                GROUP BY s.Z_PK
                ORDER BY last DESC
                """, arguments: [WhatsAppSchema.groupSuffix])
            .map { row in
                SourceConversation(
                    id: row["jid"], name: (row["name"] as String?) ?? "(sans nom)", isGroup: true,
                    messageCount: row["n"],
                    firstMessageAt: (row["first"] as Double?).map(Date.init(timeIntervalSinceReferenceDate:)),
                    lastMessageAt: (row["last"] as Double?).map(Date.init(timeIntervalSinceReferenceDate:)))
            }
        }
    }

    private func chatPK(_ db: Database, _ jid: String) throws -> Int64 {
        guard let pk = try Int64.fetchOne(db, sql: "SELECT Z_PK FROM ZWACHATSESSION WHERE ZCONTACTJID = ?",
                                          arguments: [jid]) else {
            throw SourceError.unknownConversation(jid)
        }
        return pk
    }

    private func profileNames(_ db: Database) throws -> [String: String] {
        guard hasProfileNames else { return [:] }
        var out: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") {
            if let jid: String = row["ZJID"], let name: String = row["ZPUSHNAME"],
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                out[jid] = name
            }
        }
        return out
    }

    /// Membres du groupe : Z_PK -> (jid, nom).
    private func members(_ db: Database, chat: Int64) throws -> [Int64: (String, String?)] {
        let cols = Set(try db.columns(in: "ZWAGROUPMEMBER").map(\.name))
        let nameCols = ["ZCONTACTNAME", "ZFIRSTNAME"].filter(cols.contains)
        let select = (["Z_PK", "ZMEMBERJID"] + nameCols).joined(separator: ", ")
        let profiles = try profileNames(db)
        var out: [Int64: (String, String?)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT \(select) FROM ZWAGROUPMEMBER WHERE ZCHATSESSION = ?",
                                    arguments: [chat]) {
            guard let jid: String = row["ZMEMBERJID"] else { continue }
            let local = nameCols.lazy.compactMap { row[$0] as String? }
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            out[row["Z_PK"]] = (jid, local ?? profiles[jid])
        }
        return out
    }

    func listAuthors(in conversationId: String) throws -> [SourceAuthor] {
        try db().read { db in
            let chat = try chatPK(db, conversationId)
            return try members(db, chat: chat).values.map { jid, name in
                SourceAuthor(id: jid, displayName: name, mentionToken: jid.split(separator: "@").first.map(String.init))
            }
        }
    }

    func fetchMessages(in conversationId: String, after cursor: SyncCursor?, since: Date?) throws -> [SourceMessage] {
        try db().read { db in
            let chat = try chatPK(db, conversationId)
            let members = try members(db, chat: chat)
            var joins = "LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM"
            var receipt = "NULL"
            if hasMessageInfo {
                joins += messageInfoByPK
                    ? " LEFT JOIN ZWAMESSAGEINFO inf ON inf.Z_PK = m.ZMESSAGEINFO"
                    : " LEFT JOIN ZWAMESSAGEINFO inf ON inf.ZMESSAGE = m.Z_PK"
                receipt = "inf.ZRECEIPTINFO"
            }
            let hasTitle = try db.columns(in: "ZWAMEDIAITEM").contains(where: { $0.name == "ZTITLE" })
            let titleCol = hasTitle ? "mi.ZTITLE" : "NULL"
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.Z_PK AS pk, m.ZSTANZAID AS stanza, m.ZMESSAGEDATE AS date,
                       m.ZISFROMME AS fromMe, m.ZMESSAGETYPE AS type, m.ZTEXT AS text,
                       m.ZGROUPMEMBER AS member, mi.ZMETADATA AS meta, \(titleCol) AS title,
                       \(receipt) AS receipt
                FROM ZWAMESSAGE m \(joins)
                WHERE m.ZCHATSESSION = ? AND m.Z_PK > ? AND m.ZMESSAGEDATE >= ?
                ORDER BY m.Z_PK
                """, arguments: [chat, cursor?.sequence ?? 0,
                                 since?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude])
            return rows.compactMap { row -> SourceMessage? in
                guard let stanza: String = row["stanza"], let date: Double = row["date"] else { return nil }
                let fromMe = (row["fromMe"] as Int?) == 1
                let (kind, label) = WhatsAppSchema.kind(of: row["type"] ?? -1)
                var authorId = "me", authorName: String? = nil
                if !fromMe {
                    if let pk: Int64 = row["member"], let m = members[pk] {
                        authorId = m.0
                        authorName = m.1
                    } else {
                        authorId = "inconnu"
                    }
                }
                var mediaLabel = label
                if label == "document", let title: String = row["title"], !title.isEmpty {
                    mediaLabel = "document : \(title)"
                }
                let meta: Data? = row["meta"]
                let reply = meta.flatMap { m in
                    Protobuf.strings(m).first { $0.path == WhatsAppSchema.replyIdPath }?.value
                }
                let receiptData: Data? = row["receipt"]
                let reactions = receiptData.map { r in
                    Protobuf.strings(r).filter {
                        $0.path.split(separator: ".").first.map(String.init) == WhatsAppSchema.reactionsField
                            && Emoji.isEmoji($0.value)
                    }.count
                } ?? 0
                let text: String? = row["text"]
                return SourceMessage(
                    sourceId: stanza, conversationId: conversationId, authorId: authorId,
                    authorDisplayName: fromMe ? nil : authorName,
                    sentAt: Date(timeIntervalSinceReferenceDate: date),
                    text: text?.isEmpty == true ? nil : text, kind: kind, mediaLabel: mediaLabel,
                    replyToSourceId: reply, reactionCount: reactions, sequence: row["pk"])
            }
        }
    }
}

enum Emoji {
    static func isEmoji(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 4 else { return false }
        return s.unicodeScalars.allSatisfy { $0.value >= 0x2000 || $0 == "\u{200D}" || $0 == "\u{FE0F}" }
    }
}
