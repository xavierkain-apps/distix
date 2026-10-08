import Foundation
import GRDB

extension MessageKind: DatabaseValueConvertible {}
extension ThreadRecord.State: DatabaseValueConvertible {}
extension FicheStatus: DatabaseValueConvertible {}
extension ReadState: DatabaseValueConvertible {}
extension GroupMode: DatabaseValueConvertible {}
extension ReviewState: DatabaseValueConvertible {}

public extension Notification.Name {
    /// Émise après toute écriture visible dans l'interface.
    static let distixStoreDidChange = Notification.Name("DistiXStoreDidChange")
}

/// Accès aux données de DistiX : seul endroit qui écrit du SQL métier.
public final class Store: @unchecked Sendable {
    public let db: AppDatabase
    private var writer: any DatabaseWriter { db.writer }

    public init(_ db: AppDatabase) { self.db = db }

    func notify() {
        NotificationCenter.default.post(name: .distixStoreDidChange, object: nil)
    }

    // MARK: Conversations

    public func conversations() throws -> [ConversationRecord] {
        try writer.read { db in
            try ConversationRecord.order(Column("selected").desc, Column("lastMessageAt").desc).fetchAll(db)
        }
    }

    public func selectedConversations() throws -> [ConversationRecord] {
        try writer.read { db in
            try ConversationRecord.filter(Column("selected") == true).order(Column("name")).fetchAll(db)
        }
    }

    public func conversation(_ id: String) throws -> ConversationRecord? {
        try writer.read { db in try ConversationRecord.fetchOne(db, key: id) }
    }

    /// Met à jour la liste des groupes connus (nom, volume) sans toucher à la sélection.
    public func upsertConversations(_ list: [SourceConversation], source: String) throws {
        try writer.write { db in
            for c in list {
                let id = ConversationRecord.makeId(source: source, sourceId: c.id)
                if var existing = try ConversationRecord.fetchOne(db, key: id) {
                    existing.name = c.name
                    existing.messageCount = c.messageCount
                    existing.lastMessageAt = c.lastMessageAt
                    try existing.update(db)
                } else {
                    try ConversationRecord(id: id, source: source, sourceId: c.id, name: c.name, selected: false,
                                           messageCount: c.messageCount, lastMessageAt: c.lastMessageAt,
                                           historyStart: nil, cursorSequence: nil, cursorDate: nil,
                                           lastSyncedAt: nil, syncIntervalHours: nil, mode: .knowledge, focus: nil,
                                           language: nil).insert(db)
                }
            }
        }
        notify()
    }

    public func setSelected(_ id: String, selected: Bool, historyStart: Date?) throws {
        try writer.write { db in
            guard var c = try ConversationRecord.fetchOne(db, key: id) else { return }
            c.selected = selected
            if selected {
                // Historique élargi : on relit la source depuis le début (les messages déjà
                // présents sont ignorés à l'insertion), sinon le curseur empêcherait de
                // récupérer les messages plus anciens.
                let before = c.historyStart ?? .distantPast
                let after = historyStart ?? .distantPast
                if c.cursorSequence != nil && after < before {
                    c.cursorSequence = nil
                    c.cursorDate = nil
                }
                c.historyStart = historyStart
            }
            try c.update(db)
        }
        notify()
    }

    /// Messages exploitables (texte ou média) stockés pour un groupe.
    public func usableMessageCount(in conversationId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ? AND kind IN ('text', 'media')",
                             arguments: [conversationId]) ?? 0
        }
    }

    public func setLanguage(_ id: String, language: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET language = ? WHERE id = ?", arguments: [language, id])
        }
        notify()
    }

    public func saveTranslation(ficheId: String, content: FicheContent, language: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE fiches SET translation = ?, translationLanguage = ? WHERE id = ?",
                           arguments: [try JSONEncoder.distix.encode(content), language, ficheId])
        }
        notify()
    }

    public func setGoal(_ id: String, mode: GroupMode, focus: String?) throws {
        let clean = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET mode = ?, focus = ? WHERE id = ?",
                           arguments: [mode, clean?.isEmpty == false ? clean : nil, id])
        }
        notify()
    }

    // MARK: Opportunités (mode veille)

    public func saveOpportunities(_ list: [OpportunityRecord], markAttributed messageIds: [Int64]) throws {
        try writer.write { db in
            for var o in list { try o.insert(db, onConflict: .ignore) }
            _ = try MessageRecord.filter(messageIds.contains(Column("id"))).updateAll(db, Column("attributed").set(to: true))
        }
        if !list.isEmpty { notify() }
    }

    public func opportunities(conversationId: String? = nil, unreadOnly: Bool = false,
                              search: String? = nil) throws -> [OpportunityRecord] {
        try writer.read { db in
            var r = OpportunityRecord.all()
            if let c = conversationId { r = r.filter(Column("conversationId") == c) }
            if unreadOnly { r = r.filter(Column("readAt") == nil) }
            if let text = search?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT o.id FROM opportunities o JOIN messages m ON m.id = o.messageId
                    WHERE o.summary LIKE ? OR o.reason LIKE ? OR m.text LIKE ?
                    """, arguments: StatementArguments(Array(repeating: "%\(text)%", count: 3)))
                r = r.filter(ids.contains(Column("id")))
            }
            return try r.order(Column("sentAt").desc).fetchAll(db)
        }
    }

    public func opportunity(_ id: Int64) throws -> OpportunityRecord? {
        try writer.read { db in try OpportunityRecord.fetchOne(db, key: id) }
    }

    public func message(_ id: Int64) throws -> MessageRecord? {
        try writer.read { db in try MessageRecord.fetchOne(db, key: id) }
    }

    /// Messages voisins (même conversation) pour donner le contexte d'une opportunité.
    public func messagesAround(_ message: MessageRecord, before: Int, after: Int) throws -> [MessageRecord] {
        try writer.read { db in
            let prev = try MessageRecord.filter(Column("conversationId") == message.conversationId
                                                && Column("sentAt") < message.sentAt && Column("kind") != "system")
                .order(Column("sentAt").desc).limit(before).fetchAll(db).reversed()
            let next = try MessageRecord.filter(Column("conversationId") == message.conversationId
                                                && Column("sentAt") > message.sentAt && Column("kind") != "system")
                .order(Column("sentAt")).limit(after).fetchAll(db)
            return Array(prev) + [message] + next
        }
    }

    public func markOpportunityRead(_ id: Int64, read: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE opportunities SET readAt = \(read ? "COALESCE(readAt, ?)" : "NULL") WHERE id = ?",
                           arguments: read ? [Date(), id] : [id])
        }
        notify()
    }

    public func setSyncInterval(_ id: String, hours: Double?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE conversations SET syncIntervalHours = ? WHERE id = ?", arguments: [hours, id])
        }
        notify()
    }

    /// Supprime toutes les données locales d'un groupe (messages, fils, fiches, thèmes)
    /// et remet son curseur à zéro.
    public func deleteData(of conversationId: String) throws {
        try writer.write { db in
            let ficheIds = try String.fetchAll(db, sql: "SELECT id FROM fiches WHERE conversationId = ?",
                                               arguments: [conversationId])
            for f in ficheIds {
                try db.execute(sql: "DELETE FROM fiches_fts WHERE ficheId = ?", arguments: [f])
            }
            for table in ["opportunities", "fiches", "threads", "messages", "authors", "themes"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE conversationId = ?", arguments: [conversationId])
            }
            try db.execute(sql: """
                UPDATE conversations SET cursorSequence = NULL, cursorDate = NULL, lastSyncedAt = NULL
                WHERE id = ?
                """, arguments: [conversationId])
        }
        notify()
    }

    // MARK: Ingestion

    /// Enregistre les messages lus dans la source et avance le curseur, dans une seule
    /// transaction : le curseur n'avance jamais sans les messages (brief § 6.6).
    @discardableResult
    public func ingest(conversationId: String, authors: [SourceAuthor], messages: [SourceMessage],
                       cursor: SyncCursor?) throws -> Int {
        try writer.write { db in
            var authorIds: [String: Int64] = [:]
            var nextAlias = (try Int.fetchOne(db, sql: "SELECT MAX(aliasNumber) FROM authors WHERE conversationId = ?",
                                               arguments: [conversationId]) ?? 0) + 1
            func authorId(_ sourceId: String, name: String?, token: String?, phone: String? = nil) throws -> Int64 {
                if let id = authorIds[sourceId] { return id }
                if var a = try AuthorRecord.filter(Column("conversationId") == conversationId
                                                   && Column("sourceAuthorId") == sourceId).fetchOne(db) {
                    if let name, name != a.displayName { a.displayName = name; try a.update(db) }
                    if a.mentionToken == nil, let token { a.mentionToken = token; try a.update(db) }
                    if a.phone == nil, let phone { a.phone = phone; try a.update(db) }
                    authorIds[sourceId] = a.id!
                    return a.id!
                }
                var a = AuthorRecord(id: nil, conversationId: conversationId, sourceAuthorId: sourceId,
                                     displayName: name, aliasNumber: sourceId == "me" ? 0 : nextAlias,
                                     mentionToken: token, phone: phone)
                if sourceId != "me" { nextAlias += 1 }
                try a.insert(db)
                authorIds[sourceId] = a.id!
                return a.id!
            }
            for a in authors { _ = try authorId(a.id, name: a.displayName, token: a.mentionToken, phone: a.phone) }
            var inserted = 0
            for m in messages {
                let aid = try authorId(m.authorId, name: m.authorDisplayName, token: nil)
                var rec = MessageRecord(id: nil, conversationId: conversationId, sourceId: m.sourceId, authorId: aid,
                                        sentAt: m.sentAt, text: m.text, kind: m.kind, mediaLabel: m.mediaLabel,
                                        replyToSourceId: m.replyToSourceId, reactionCount: m.reactionCount,
                                        sequence: m.sequence,
                                        attributed: m.kind == .system || m.kind == .deleted)
                try rec.insert(db, onConflict: .ignore)
                if db.changesCount > 0 { inserted += 1 }
            }
            if let cursor {
                try db.execute(sql: """
                    UPDATE conversations SET cursorSequence = ?, cursorDate = ?, lastSyncedAt = ? WHERE id = ?
                    """, arguments: [cursor.sequence, cursor.date, Date(), conversationId])
            } else {
                try db.execute(sql: "UPDATE conversations SET lastSyncedAt = ? WHERE id = ?",
                               arguments: [Date(), conversationId])
            }
            return inserted
        }
    }

    public func author(_ id: Int64) throws -> AuthorRecord? {
        try writer.read { db in try AuthorRecord.fetchOne(db, key: id) }
    }

    public func authors(in conversationId: String) throws -> [Int64: AuthorRecord] {
        try writer.read { db in
            Dictionary(uniqueKeysWithValues: try AuthorRecord.filter(Column("conversationId") == conversationId)
                .fetchAll(db).map { ($0.id!, $0) })
        }
    }

    // MARK: Attribution aux fils

    public func pendingMessages(in conversationId: String, limit: Int) throws -> [MessageRecord] {
        try writer.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && Column("attributed") == false)
                .order(Column("sentAt"), Column("sequence")).limit(limit).fetchAll(db)
        }
    }

    public func pendingCount(in conversationId: String) throws -> Int {
        try writer.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && Column("attributed") == false).fetchCount(db)
        }
    }

    /// Messages déjà traités juste avant `date`, pour donner du contexte (recouvrement).
    public func contextMessages(in conversationId: String, before date: Date, limit: Int) throws -> [MessageRecord] {
        try writer.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && Column("attributed") == true
                                     && Column("sentAt") < date && Column("kind") != MessageKind.system.rawValue
                                     && Column("kind") != MessageKind.deleted.rawValue)
                .order(Column("sentAt").desc).limit(limit).fetchAll(db).reversed()
        }
    }

    public func messages(sourceIds: [String], in conversationId: String) throws -> [MessageRecord] {
        guard !sourceIds.isEmpty else { return [] }
        return try writer.read { db in
            try MessageRecord.filter(Column("conversationId") == conversationId && sourceIds.contains(Column("sourceId")))
                .fetchAll(db)
        }
    }

    /// Fil de chaque message (par identifiant interne).
    public func threadIds(forMessages ids: [Int64]) throws -> [Int64: Int64] {
        guard !ids.isEmpty else { return [:] }
        return try writer.read { db in
            var out: [Int64: Int64] = [:]
            for r in try ThreadMessageRecord.filter(ids.contains(Column("messageId"))).fetchAll(db) {
                out[r.messageId] = r.threadId
            }
            return out
        }
    }

    /// Fils ouverts : état ouvert et dernier message il y a moins de `openDays` jours
    /// par rapport à `reference` (date des messages traités, pas l'horloge).
    public func openThreads(in conversationId: String, reference: Date, openDays: Int) throws -> [ThreadRecord] {
        let limit = reference.addingTimeInterval(-Double(openDays) * 86_400)
        return try writer.write { db in
            try db.execute(sql: """
                UPDATE threads SET state = 'closed'
                WHERE conversationId = ? AND state = 'open' AND lastMessageAt < ?
                """, arguments: [conversationId, limit])
            return try ThreadRecord.filter(Column("conversationId") == conversationId && Column("state") == "open")
                .order(Column("lastMessageAt").desc).fetchAll(db)
        }
    }

    public func threadMessages(_ threadId: Int64, last: Int? = nil) throws -> [MessageRecord] {
        try writer.read { db in
            let sql = """
                SELECT m.* FROM messages m JOIN thread_messages tm ON tm.messageId = m.id
                WHERE tm.threadId = ? ORDER BY m.sentAt DESC \(last.map { "LIMIT \($0)" } ?? "")
                """
            return try MessageRecord.fetchAll(db, sql: sql, arguments: [threadId]).reversed()
        }
    }

    public struct Assignment {
        public enum Target { case existing(Int64), new(key: String), none }
        public let messageId: Int64
        public let target: Target
        public init(messageId: Int64, target: Target) { self.messageId = messageId; self.target = target }
    }

    /// Applique le résultat d'une fenêtre d'attribution, en une transaction.
    public func applyAttribution(conversationId: String, assignments: [Assignment],
                                 newThreads: [String: String]) throws {
        try writer.write { db in
            var created: [String: Int64] = [:]
            let messages = Dictionary(uniqueKeysWithValues: try MessageRecord
                .filter(assignments.map(\.messageId).contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) })
            for a in assignments {
                guard let m = messages[a.messageId] else { continue }
                var threadId: Int64?
                switch a.target {
                case .existing(let id): threadId = id
                case .new(let key):
                    if let id = created[key] { threadId = id }
                    else {
                        var t = ThreadRecord(id: nil, conversationId: conversationId, state: .open,
                                             summary: newThreads[key] ?? "", firstMessageAt: m.sentAt,
                                             lastMessageAt: m.sentAt, needsFiche: true, skipReason: nil)
                        try t.insert(db)
                        created[key] = t.id!
                        threadId = t.id!
                    }
                case .none: threadId = nil
                }
                if let threadId {
                    try ThreadMessageRecord(threadId: threadId, messageId: a.messageId).insert(db, onConflict: .ignore)
                    try db.execute(sql: """
                        UPDATE threads SET needsFiche = 1, state = 'open',
                            lastMessageAt = MAX(lastMessageAt, ?), firstMessageAt = MIN(firstMessageAt, ?)
                        WHERE id = ?
                        """, arguments: [m.sentAt, m.sentAt, threadId])
                }
                try db.execute(sql: "UPDATE messages SET attributed = 1 WHERE id = ?", arguments: [a.messageId])
            }
        }
    }

    public func threadsNeedingFiche(in conversationId: String) throws -> [ThreadRecord] {
        try writer.read { db in
            try ThreadRecord.filter(Column("conversationId") == conversationId && Column("needsFiche") == true)
                .order(Column("firstMessageAt")).fetchAll(db)
        }
    }

    public func clearNeedsFiche(_ threadIds: [Int64]) throws {
        try writer.write { db in
            _ = try ThreadRecord.filter(threadIds.contains(Column("id"))).updateAll(db, Column("needsFiche").set(to: false))
        }
    }

    public func setSkipReason(_ threadIds: [Int64], reason: String?) throws {
        try writer.write { db in
            _ = try ThreadRecord.filter(threadIds.contains(Column("id"))).updateAll(db, Column("skipReason").set(to: reason))
        }
    }

    /// Fils d'une conversation avec leur nombre de messages (pour le diagnostic local).
    public func threads(in conversationId: String?) throws -> [(thread: ThreadRecord, messages: Int, ficheId: String?)] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, COUNT(tm.messageId) AS n, ft.ficheId AS fiche FROM threads t
                LEFT JOIN thread_messages tm ON tm.threadId = t.id
                LEFT JOIN fiche_threads ft ON ft.threadId = t.id
                \(conversationId == nil ? "" : "WHERE t.conversationId = ?")
                GROUP BY t.id ORDER BY t.firstMessageAt
                """, arguments: conversationId.map { [$0] } ?? [])
            return try rows.compactMap { row in
                guard let t = try ThreadRecord.fetchOne(db, key: row["id"] as Int64) else { return nil }
                return (t, row["n"], row["fiche"])
            }
        }
    }

    public func updateThreadSummary(_ threadId: Int64, summary: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE threads SET summary = ? WHERE id = ?", arguments: [summary, threadId])
        }
    }

    // MARK: Fiches

    public func ficheId(forThread threadId: Int64) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT ficheId FROM fiche_threads WHERE threadId = ?", arguments: [threadId])
        }
    }

    public func threadIds(ofFiche ficheId: String) throws -> [Int64] {
        try writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT threadId FROM fiche_threads WHERE ficheId = ? ORDER BY addedAt",
                               arguments: [ficheId])
        }
    }

    public func ficheThreads(_ ficheId: String) throws -> [FicheThreadRecord] {
        try writer.read { db in
            try FicheThreadRecord.filter(Column("ficheId") == ficheId).order(Column("addedAt")).fetchAll(db)
        }
    }

    /// Tous les messages des fils d'une fiche, dans l'ordre chronologique.
    public func messages(ofFiche ficheId: String) throws -> [MessageRecord] {
        try writer.read { db in
            try MessageRecord.fetchAll(db, sql: """
                SELECT m.* FROM messages m
                JOIN thread_messages tm ON tm.messageId = m.id
                JOIN fiche_threads ft ON ft.threadId = tm.threadId
                WHERE ft.ficheId = ? ORDER BY m.sentAt, m.sequence
                """, arguments: [ficheId])
        }
    }

    public func messages(ofThreads threadIds: [Int64]) throws -> [MessageRecord] {
        try writer.read { db in
            try MessageRecord.fetchAll(db, sql: """
                SELECT m.* FROM messages m JOIN thread_messages tm ON tm.messageId = m.id
                WHERE tm.threadId IN (\(threadIds.map(String.init).joined(separator: ",")))
                ORDER BY m.sentAt, m.sequence
                """)
        }
    }

    public func fiche(_ id: String) throws -> FicheRecord? {
        try writer.read { db in try FicheRecord.fetchOne(db, key: id) }
    }

    public func themes(in conversationId: String) throws -> [ThemeRecord] {
        try writer.read { db in
            try ThemeRecord.filter(Column("conversationId") == conversationId).order(Column("name")).fetchAll(db)
        }
    }

    public func themeId(named name: String, in conversationId: String) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM themes WHERE conversationId = ? AND name = ? COLLATE NOCASE",
                                           arguments: [conversationId, clean]) {
                return id
            }
            var t = ThemeRecord(id: nil, conversationId: conversationId, name: clean.isEmpty ? "Divers" : clean, objective: nil)
            try t.insert(db)
            return t.id!
        }
    }

    /// Enregistre une fiche et ses fils, et met à jour l'index de recherche.
    public func saveFiche(_ fiche: FicheRecord, threadIds: [Int64], mergedFrom: [Int64: String] = [:]) throws {
        try writer.write { db in
            try fiche.save(db)
            for t in threadIds {
                if try FicheThreadRecord.filter(Column("threadId") == t).fetchOne(db) == nil {
                    try FicheThreadRecord(ficheId: fiche.id, threadId: t, addedAt: Date(),
                                          mergedFromFicheId: mergedFrom[t]).insert(db)
                }
            }
            try Self.index(fiche, db)
        }
        notify()
    }

    static func index(_ fiche: FicheRecord, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM fiches_fts WHERE ficheId = ?", arguments: [fiche.id])
        let c = fiche.decoded
        try db.execute(sql: "INSERT INTO fiches_fts (ficheId, question, context, answers) VALUES (?, ?, ?, ?)",
                       arguments: [fiche.id, fiche.question, c?.context ?? "", c?.answersText ?? ""])
    }

    public func deleteFiche(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM fiches_fts WHERE ficheId = ?", arguments: [id])
            _ = try FicheRecord.deleteOne(db, key: id)
        }
        notify()
    }

    /// Déplace des fils d'une fiche vers une autre (fusion), en gardant la trace.
    public func moveThreads(_ threadIds: [Int64], from source: String, to target: String) throws {
        try writer.write { db in
            for t in threadIds {
                try db.execute(sql: """
                    UPDATE fiche_threads SET ficheId = ?, mergedFromFicheId = COALESCE(mergedFromFicheId, ?), addedAt = ?
                    WHERE threadId = ?
                    """, arguments: [target, source, Date(), t])
            }
        }
    }

    /// Rattache des fils à une fiche, sans trace de fusion (pour défaire une fusion).
    public func detachThreads(_ threadIds: [Int64], to ficheId: String) throws {
        try writer.write { db in
            for t in threadIds {
                try db.execute(sql: "UPDATE fiche_threads SET ficheId = ?, mergedFromFicheId = NULL, addedAt = ? WHERE threadId = ?",
                               arguments: [ficheId, Date(), t])
            }
        }
        notify()
    }

    public func fichesWithEmbedding(in conversationIds: [String], excluding id: String) throws -> [FicheRecord] {
        try writer.read { db in
            try FicheRecord.filter(conversationIds.contains(Column("conversationId")) && Column("id") != id
                                   && Column("embedding") != nil).fetchAll(db)
        }
    }

    // MARK: Interface

    public struct FicheQuery: Sendable {
        public var conversationId: String?
        public var themeId: Int64?
        public var unreadOnly = false
        public var status: FicheStatus?
        public var search: String?
        public var review: ReviewFilter = .kept
        public init(conversationId: String? = nil, themeId: Int64? = nil, unreadOnly: Bool = false,
                    status: FicheStatus? = nil, search: String? = nil, review: ReviewFilter = .kept) {
            self.conversationId = conversationId; self.themeId = themeId; self.unreadOnly = unreadOnly
            self.status = status; self.search = search; self.review = review
        }
    }

    public enum ReviewFilter: String, CaseIterable, Sendable {
        /// Toutes sauf les écartées (par défaut).
        case kept
        case toReview, validated, discarded, all
    }

    public func fiches(_ q: FicheQuery) throws -> [FicheRecord] {
        try writer.read { db in
            var request = FicheRecord.all()
            if let c = q.conversationId { request = request.filter(Column("conversationId") == c) }
            if let t = q.themeId { request = request.filter(Column("themeId") == t) }
            if q.unreadOnly { request = request.filter(Column("readAt") == nil) }
            if let s = q.status { request = request.filter(Column("status") == s.rawValue) }
            switch q.review {
            case .kept: request = request.filter(Column("review") == nil || Column("review") != ReviewState.discarded.rawValue)
            case .toReview: request = request.filter(Column("review") == nil)
            case .validated: request = request.filter(Column("review") == ReviewState.validated.rawValue)
            case .discarded: request = request.filter(Column("review") == ReviewState.discarded.rawValue)
            case .all: break
            }
            if let text = q.search?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let ids = try String.fetchAll(db, sql: "SELECT ficheId FROM fiches_fts WHERE fiches_fts MATCH ? ORDER BY rank",
                                              arguments: [Self.ftsQuery(text)])
                request = request.filter(ids.contains(Column("id")))
            }
            return try request.order(Column("lastMessageAt").desc).fetchAll(db)
        }
    }

    /// Transforme une saisie libre en requête FTS5 sûre (préfixes, ET implicite).
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
    }

    public func unreadCounts() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT conversationId, COUNT(*) AS n FROM (
                    SELECT conversationId FROM fiches WHERE readAt IS NULL AND (review IS NULL OR review != 'discarded')
                    UNION ALL SELECT conversationId FROM opportunities WHERE readAt IS NULL)
                GROUP BY 1
                """) {
                out[row["conversationId"]] = row["n"]
            }
            return out
        }
    }

    public func ficheCountsByTheme(in conversationId: String) throws -> [Int64: (total: Int, unread: Int)] {
        try writer.read { db in
            var out: [Int64: (total: Int, unread: Int)] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT themeId, COUNT(*) AS n, SUM(readAt IS NULL) AS u FROM fiches
                WHERE conversationId = ? AND themeId IS NOT NULL AND (review IS NULL OR review != 'discarded')
                GROUP BY themeId
                """, arguments: [conversationId]) {
                let id: Int64 = row["themeId"]
                out[id] = (total: row["n"], unread: row["u"])
            }
            return out
        }
    }

    /// Valide ou écarte une fiche (nil = à trier). Une fiche écartée est aussi marquée lue.
    public func setReview(_ id: String, _ review: ReviewState?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE fiches SET review = ? WHERE id = ?", arguments: [review, id])
            if review == .discarded {
                try db.execute(sql: "UPDATE fiches SET readAt = COALESCE(readAt, ?) WHERE id = ?", arguments: [Date(), id])
            }
        }
        notify()
    }

    public func markRead(_ id: String, read: Bool) throws {
        try writer.write { db in
            if read {
                try db.execute(sql: "UPDATE fiches SET readAt = ? WHERE id = ? AND readAt IS NULL", arguments: [Date(), id])
            } else {
                try db.execute(sql: "UPDATE fiches SET readAt = NULL, readState = COALESCE(readState, 'updated') WHERE id = ?",
                               arguments: [id])
            }
        }
        notify()
    }

    public func markAllRead(conversationId: String? = nil) throws {
        try writer.write { db in
            for table in ["fiches", "opportunities"] {
                if let conversationId {
                    try db.execute(sql: "UPDATE \(table) SET readAt = ? WHERE readAt IS NULL AND conversationId = ?",
                                   arguments: [Date(), conversationId])
                } else {
                    try db.execute(sql: "UPDATE \(table) SET readAt = ? WHERE readAt IS NULL", arguments: [Date()])
                }
            }
        }
        notify()
    }

    public func setTheme(ficheId: String, themeName: String) throws {
        guard let f = try fiche(ficheId) else { return }
        let tid = try themeId(named: themeName, in: f.conversationId)
        try writer.write { db in
            try db.execute(sql: "UPDATE fiches SET themeId = ? WHERE id = ?", arguments: [tid, ficheId])
            if var c = f.decoded {
                c.theme = themeName
                try db.execute(sql: "UPDATE fiches SET content = ? WHERE id = ?",
                               arguments: [try JSONEncoder.distix.encode(c), ficheId])
            }
        }
        notify()
    }

    /// Crée ou modifie un thème défini par l'utilisateur (nom et objectif).
    @discardableResult
    public func saveTheme(id: Int64?, conversationId: String, name: String, objective: String?) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid: Int64
        if let id {
            try renameTheme(id, to: clean)
            tid = try writer.read { db in
                try Int64.fetchOne(db, sql: "SELECT id FROM themes WHERE conversationId = ? AND name = ?",
                                   arguments: [conversationId, clean]) ?? id
            }
        } else {
            tid = try themeId(named: clean, in: conversationId)
        }
        try writer.write { db in
            try db.execute(sql: "UPDATE themes SET objective = ? WHERE id = ?",
                           arguments: [goal?.isEmpty == false ? goal : nil, tid])
        }
        notify()
        return tid
    }

    public func renameTheme(_ id: Int64, to name: String) throws {
        try writer.write { db in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, let theme = try ThemeRecord.fetchOne(db, key: id) else { return }
            if let other = try ThemeRecord.filter(Column("conversationId") == theme.conversationId
                                                 && Column("name") == clean && Column("id") != id).fetchOne(db) {
                // Un thème du même nom existe : fusion.
                try db.execute(sql: "UPDATE fiches SET themeId = ? WHERE themeId = ?", arguments: [other.id, id])
                _ = try ThemeRecord.deleteOne(db, key: id)
            } else {
                try db.execute(sql: "UPDATE themes SET name = ? WHERE id = ?", arguments: [clean, id])
            }
        }
        notify()
    }

    public func mergeThemes(_ source: Int64, into target: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE fiches SET themeId = ? WHERE themeId = ?", arguments: [target, source])
            _ = try ThemeRecord.deleteOne(db, key: source)
        }
        notify()
    }

    public func themeName(_ id: Int64?) throws -> String? {
        guard let id else { return nil }
        return try writer.read { db in try String.fetchOne(db, sql: "SELECT name FROM themes WHERE id = ?", arguments: [id]) }
    }

    /// Volumes, sans aucun contenu (pour les diagnostics).
    public func statistics() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            for (k, sql) in [("messages", "SELECT COUNT(*) FROM messages"),
                             ("messages en attente de traitement", "SELECT COUNT(*) FROM messages WHERE attributed = 0"),
                             ("messages rattachés à un fil", "SELECT COUNT(*) FROM thread_messages"),
                             ("messages écartés (bavardage, hors sujet)", """
                                SELECT COUNT(*) FROM messages m WHERE m.attributed = 1 AND m.kind IN ('text', 'media')
                                AND NOT EXISTS (SELECT 1 FROM thread_messages tm WHERE tm.messageId = m.id)
                                """),
                             ("messages système ou supprimés", "SELECT COUNT(*) FROM messages WHERE kind IN ('system', 'deleted')"),
                             ("fils", "SELECT COUNT(*) FROM threads"),
                             ("fils écartés (sans fiche)", "SELECT COUNT(*) FROM threads WHERE skipReason IS NOT NULL"),
                             ("fiches", "SELECT COUNT(*) FROM fiches"),
                             ("fiches répondues", "SELECT COUNT(*) FROM fiches WHERE status = 'repondue'"),
                             ("fiches débattues", "SELECT COUNT(*) FROM fiches WHERE status = 'debattue'"),
                             ("fiches sans réponse", "SELECT COUNT(*) FROM fiches WHERE status = 'sans_reponse'"),
                             ("fiches issues d'une fusion",
                              "SELECT COUNT(DISTINCT ficheId) FROM fiche_threads WHERE mergedFromFicheId IS NOT NULL"),
                             ("thèmes", "SELECT COUNT(*) FROM themes"),
                             ("opportunités (veille)", "SELECT COUNT(*) FROM opportunities"),
                             ("fiches non lues", "SELECT COUNT(*) FROM fiches WHERE readAt IS NULL"),
                             ("fiches validées", "SELECT COUNT(*) FROM fiches WHERE review = 'validated'"),
                             ("fiches écartées", "SELECT COUNT(*) FROM fiches WHERE review = 'discarded'")] {
                out[k] = try Int.fetchOne(db, sql: sql) ?? 0
            }
            return out
        }
    }

    // MARK: Journal des synchronisations

    public func startRun() throws -> SyncRunRecord {
        try writer.write { db in
            var r = SyncRunRecord(startedAt: Date())
            try r.insert(db)
            return r
        }
    }

    public func saveRun(_ run: SyncRunRecord) throws {
        try writer.write { db in try run.update(db) }
        notify()
    }

    public func lastRun() throws -> SyncRunRecord? {
        try writer.read { db in try SyncRunRecord.order(Column("startedAt").desc).fetchOne(db) }
    }
}
