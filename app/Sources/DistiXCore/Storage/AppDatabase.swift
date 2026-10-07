import Foundation
import GRDB

/// Base locale de DistiX (GRDB). Migrations versionnées dès le départ.
public final class AppDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Base dans ~/Library/Application Support/DistiX/.
    public static func openDefault() throws -> AppDatabase {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("DistiX", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try open(at: dir.appendingPathComponent("distix.sqlite"))
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: url.path, configuration: config))
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "conversations") { t in
                t.primaryKey("id", .text)
                t.column("source", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("selected", .boolean).notNull().defaults(to: false)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("lastMessageAt", .datetime)
                t.column("historyStart", .datetime)
                t.column("cursorSequence", .integer)
                t.column("cursorDate", .datetime)
                t.column("lastSyncedAt", .datetime)
            }
            try db.create(table: "authors") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("sourceAuthorId", .text).notNull()
                t.column("displayName", .text)
                t.column("aliasNumber", .integer).notNull()
                t.column("mentionToken", .text)
                t.uniqueKey(["conversationId", "sourceAuthorId"])
            }
            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("sourceId", .text).notNull()
                t.column("authorId", .integer).notNull().references("authors", onDelete: .cascade)
                t.column("sentAt", .datetime).notNull()
                t.column("text", .text)
                t.column("kind", .text).notNull()
                t.column("mediaLabel", .text)
                t.column("replyToSourceId", .text)
                t.column("reactionCount", .integer).notNull().defaults(to: 0)
                t.column("sequence", .integer).notNull()
                t.column("attributed", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["conversationId", "sourceId"])
            }
            try db.create(index: "messages_pending", on: "messages", columns: ["conversationId", "attributed", "sentAt"])
            try db.create(table: "threads") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("state", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("firstMessageAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime).notNull()
                t.column("needsFiche", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "thread_messages") { t in
                t.column("threadId", .integer).notNull().references("threads", onDelete: .cascade)
                t.column("messageId", .integer).notNull().unique().references("messages", onDelete: .cascade)
            }
            try db.create(index: "thread_messages_thread", on: "thread_messages", columns: ["threadId"])
            try db.create(table: "themes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.uniqueKey(["conversationId", "name"])
            }
            try db.create(table: "fiches") { t in
                t.primaryKey("id", .text)
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("themeId", .integer).references("themes", onDelete: .setNull)
                t.column("status", .text).notNull()
                t.column("question", .text).notNull()
                t.column("content", .blob).notNull()
                t.column("embedding", .blob)
                t.column("firstMessageAt", .datetime).notNull()
                t.column("lastMessageAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("readAt", .datetime)
                t.column("readState", .text)
                t.column("changeNote", .text)
            }
            try db.create(table: "fiche_threads") { t in
                t.column("ficheId", .text).notNull().references("fiches", onDelete: .cascade)
                t.column("threadId", .integer).notNull().unique().references("threads", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.column("mergedFromFicheId", .text)
            }
            try db.create(table: "sync_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("messagesRead", .integer).notNull().defaults(to: 0)
                t.column("fichesCreated", .integer).notNull().defaults(to: 0)
                t.column("fichesUpdated", .integer).notNull().defaults(to: 0)
                t.column("merges", .integer).notNull().defaults(to: 0)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("error", .text)
            }
            // Recherche plein texte. Table FTS5 autonome, tenue à jour par Store.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE fiches_fts USING fts5(
                    ficheId UNINDEXED, question, context, answers,
                    tokenize = 'unicode61 remove_diacritics 2')
                """)
        }
        return m
    }
}
