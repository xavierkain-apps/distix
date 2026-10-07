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

    /// Un JID « numéro@s.whatsapp.net » contient le numéro ; un « …@lid » non (voir
    /// docs/schema-whatsapp.md, la correspondance LID -> numéro reste à établir).
    static func phone(fromJid jid: String) -> String? {
        guard jid.hasSuffix("@s.whatsapp.net"), let user = jid.split(separator: "@").first,
              user.allSatisfy(\.isNumber), user.count >= 8 else { return nil }
        return "+" + user
    }

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
    private var identities = WhatsAppIdentities()

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
                    identities = WhatsAppIdentities.load(from: original.deletingLastPathComponent(), into: directory)
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

    /// Membres du groupe : Z_PK -> (jid, nom, numéro partagé).
    private func members(_ db: Database, chat: Int64) throws -> [Int64: (String, String?, String?)] {
        let cols = Set(try db.columns(in: "ZWAGROUPMEMBER").map(\.name))
        let nameCols = ["ZCONTACTNAME", "ZFIRSTNAME"].filter(cols.contains)
        let select = (["Z_PK", "ZMEMBERJID"] + nameCols).joined(separator: ", ")
        let profiles = try profileNames(db)
        var out: [Int64: (String, String?, String?)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT \(select) FROM ZWAGROUPMEMBER WHERE ZCHATSESSION = ?",
                                    arguments: [chat]) {
            guard let jid: String = row["ZMEMBERJID"] else { continue }
            let local = nameCols.lazy.compactMap { row[$0] as String? }
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            // Nom : celui du carnet d'adresses, sinon WhatsApp (local, profil, compte).
            let name = identities.contactName(jid) ?? local ?? profiles[jid] ?? identities.accountName(jid)
            out[row["Z_PK"]] = (jid, name, identities.sharedPhone(jid))
        }
        return out
    }

    func listAuthors(in conversationId: String) throws -> [SourceAuthor] {
        try db().read { db in
            let chat = try chatPK(db, conversationId)
            return try members(db, chat: chat).values.map { jid, name, phone in
                SourceAuthor(id: jid, displayName: name, mentionToken: jid.split(separator: "@").first.map(String.init),
                             phone: phone)
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

// MARK: - Noms et numéros (LID.sqlite, ContactsV2.sqlite)

/// Identités issues de deux autres bases de WhatsApp, lues comme ChatStorage (copie,
/// lecture seule). Facultatives : si elles manquent ou changent de format, on
/// continue sans (noms et numéros inconnus). Voir docs/schema-whatsapp.md.
///
/// Règle choisie par Xavier (2026-10-07) : un numéro n'est exposé que s'il est
/// partagé : contact du carnet d'adresses, membre adressé par son numéro dans le
/// groupe, ou compte dont l'état de partage vaut 1 (sens exact non documenté ; on
/// retient l'interprétation prudente). Jamais envoyé à l'IA.
struct WhatsAppIdentities {
    struct Entry { var name: String?; var phone: String? }
    private(set) var contacts: [String: Entry] = [:]       // clé : LID ou JID
    private(set) var accounts: [String: Entry] = [:]       // clé : LID ; numéro seulement si partagé
    static let sharedState = 1

    func contactName(_ jid: String) -> String? { contacts[jid]?.name }
    func accountName(_ jid: String) -> String? { accounts[jid]?.name }

    func sharedPhone(_ jid: String) -> String? {
        contacts[jid]?.phone ?? WhatsAppSchema.phone(fromJid: jid) ?? accounts[jid]?.phone
    }

    static func normalizePhone(_ raw: String?) -> String? {
        guard let digits = raw?.filter(\.isNumber), digits.count >= 8 else { return nil }
        return "+" + digits
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func load(from folder: URL, into directory: URL) -> WhatsAppIdentities {
        var out = WhatsAppIdentities()
        if let q = openCopy(folder.appendingPathComponent("ContactsV2.sqlite"), into: directory) {
            _ = try? q.read { db in
                let cols = Set(try db.columns(in: "ZWAADDRESSBOOKCONTACT").map(\.name))
                guard cols.isSuperset(of: ["ZLID", "ZWHATSAPPID", "ZFULLNAME", "ZPHONENUMBER"]) else { return }
                for row in try Row.fetchAll(db, sql: "SELECT ZLID, ZWHATSAPPID, ZFULLNAME, ZPHONENUMBER FROM ZWAADDRESSBOOKCONTACT") {
                    let e = Entry(name: clean(row["ZFULLNAME"]), phone: normalizePhone(row["ZPHONENUMBER"]))
                    for key in [row["ZLID"] as String?, row["ZWHATSAPPID"] as String?].compactMap({ $0 }) { out.contacts[key] = e }
                }
            }
        }
        if let q = openCopy(folder.appendingPathComponent("LID.sqlite"), into: directory) {
            _ = try? q.read { db in
                let cols = Set(try db.columns(in: "ZWAZACCOUNT").map(\.name))
                guard cols.isSuperset(of: ["ZIDENTIFIER", "ZDISPLAYNAME", "ZPHONENUMBER", "ZCURRENTPHONENUMBERSHARINGSTATE"]) else { return }
                for row in try Row.fetchAll(db, sql: """
                    SELECT ZIDENTIFIER, ZDISPLAYNAME, ZPHONENUMBER, ZCURRENTPHONENUMBERSHARINGSTATE FROM ZWAZACCOUNT
                    """) {
                    guard let id: String = row["ZIDENTIFIER"] else { continue }
                    let shared = (row["ZCURRENTPHONENUMBERSHARINGSTATE"] as Int?) == sharedState
                    out.accounts[id] = Entry(name: clean(row["ZDISPLAYNAME"]),
                                             phone: shared ? normalizePhone(row["ZPHONENUMBER"]) : nil)
                }
            }
        }
        return out
    }

    /// Copie la base (et ses fichiers -wal/-shm) dans `directory` et l'ouvre en lecture seule.
    private static func openCopy(_ original: URL, into directory: URL) -> DatabaseQueue? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else { return nil }
        let dest = directory.appendingPathComponent(original.lastPathComponent)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: original.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
            }
            var config = Configuration()
            config.readonly = true
            return try DatabaseQueue(path: dest.path, configuration: config)
        } catch {
            Log.core.warning("Base d'identités illisible : \(original.lastPathComponent, privacy: .public)")
            return nil
        }
    }
}
