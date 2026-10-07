import AppKit
import DistiXCore
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum SidebarItem: Hashable {
    case news
    case group(String)
    case theme(String, Int64)
}

@MainActor @Observable
final class AppModel {
    let store: Store
    let engine: SyncEngine
    let source = WhatsAppSource()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.syncIntervalHours != oldValue.syncIntervalHours { scheduleTimer() }
            if settings.launchAtLogin != oldValue.launchAtLogin { applyLoginItem() }
            if settings.notificationsEnabled && !oldValue.notificationsEnabled { requestNotifications() }
            if settings.showRealNames != oldValue.showRealNames { reloadFiches() }
        }
    }

    var conversations: [ConversationRecord] = []
    var unread: [String: Int] = [:]
    var themes: [String: [ThemeRecord]] = [:]
    var themeUnread: [Int64: Int] = [:]
    var sidebar: SidebarItem? = .news { didSet { sessionRead.removeAll(); reloadFiches() } }
    var statusFilter: FicheStatus? { didSet { reloadFiches() } }
    var searchText = "" { didSet { reloadFiches() } }
    var fiches: [FicheRecord] = []
    var selectedFicheId: String? { didSet { openedFiche() } }
    var isSyncing = false
    var syncProgress: String?
    var lastRun: SyncRunRecord?
    var alert: String?
    var showOnboarding = false
    /// Fiches lues pendant cette visite des Nouveautés : restent visibles jusqu'au changement de vue.
    @ObservationIgnored private var sessionRead: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    var totalUnread: Int { unread.values.reduce(0, +) }
    var selectedConversations: [ConversationRecord] { conversations.filter(\.selected) }

    init() {
        do {
            store = Store(try AppDatabase.openDefault())
        } catch {
            fatalError("Base locale illisible : \(error)")
        }
        engine = SyncEngine(store: store, source: source)
        settings = AppSettings.load()
        showOnboarding = !settings.onboardingDone
        observer = NotificationCenter.default.addObserver(forName: .distixStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        if settings.onboardingDone {
            scheduleTimer()
            Task { await sync() }
        }
    }

    // MARK: Données

    func reload() {
        conversations = (try? store.conversations()) ?? []
        unread = (try? store.unreadCounts()) ?? [:]
        var t: [String: [ThemeRecord]] = [:]
        var tu: [Int64: Int] = [:]
        for c in conversations where c.selected {
            t[c.id] = (try? store.themes(in: c.id)) ?? []
            for (id, counts) in (try? store.ficheCountsByTheme(in: c.id)) ?? [:] { tu[id] = counts.unread }
        }
        themes = t
        themeUnread = tu
        lastRun = try? store.lastRun()
        reloadFiches()
    }

    func reloadFiches() {
        var q = Store.FicheQuery(status: statusFilter)
        let search = searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            q.search = search
        } else {
            switch sidebar {
            case .news, nil: q.unreadOnly = true
            case .group(let id): q.conversationId = id
            case .theme(let id, let theme): q.conversationId = id; q.themeId = theme
            }
        }
        var list = (try? store.fiches(q)) ?? []
        if q.unreadOnly && !sessionRead.isEmpty {
            let kept = sessionRead.compactMap { try? store.fiche($0) }.filter { f in !list.contains { $0.id == f.id } }
            list = (list + kept).sorted { $0.lastMessageAt > $1.lastMessageAt }
        }
        fiches = list
    }

    var selectedFiche: FicheRecord? {
        selectedFicheId.flatMap { id in fiches.first { $0.id == id } ?? (try? store.fiche(id)) }
    }

    private func openedFiche() {
        guard let id = selectedFicheId, let f = try? store.fiche(id), f.isUnread else { return }
        sessionRead.insert(id)
        try? store.markRead(id, read: true)
    }

    func markUnread(_ id: String) {
        sessionRead.insert(id)
        try? store.markRead(id, read: false)
    }

    func markAllRead() {
        try? store.markAllRead()
    }

    func conversationName(_ id: String) -> String {
        conversations.first { $0.id == id }?.name ?? ""
    }

    func themeName(_ id: Int64?) -> String {
        guard let id else { return L("Sans thème") }
        return themes.values.joined().first { $0.id == id }?.name ?? L("Sans thème")
    }

    // MARK: Synchronisation

    func sync(only ids: [String]? = nil) async {
        guard !isSyncing, settings.onboardingDone || ids != nil else { return }
        isSyncing = true
        syncProgress = L("Démarrage…")
        if settings.openWhatsAppBeforeSync { await openWhatsApp() }
        let summary = await engine.run(settings: settings, only: ids) { text in
            Task { @MainActor in self.syncProgress = text }
        }
        isSyncing = false
        syncProgress = nil
        reload()
        if let summary {
            if let error = summary.error { alert = error }
            notify(summary)
        }
    }

    func syncNow() { Task { await sync() } }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(0.25, settings.syncIntervalHours) * 3600
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    func startAfterOnboarding() {
        settings.onboardingDone = true
        showOnboarding = false
        scheduleTimer()
        syncNow()
    }

    private func openWhatsApp() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else { return }
        let alreadyRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "net.whatsapp.WhatsApp" }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        // Laisser WhatsApp rattraper les messages reçus pendant son absence.
        if !alreadyRunning { try? await Task.sleep(nanoseconds: 45_000_000_000) }
    }

    // MARK: Groupes

    func refreshGroups() async -> SourceStatus {
        let status = await source.checkAvailability()
        if status == .available { _ = try? await engine.refreshConversations() }
        reload()
        return status
    }

    func setSelected(_ c: ConversationRecord, selected: Bool, historyStart: Date?) {
        try? store.setSelected(c.id, selected: selected, historyStart: historyStart)
    }

    func deleteData(of id: String) {
        try? store.deleteData(of: id)
        if case .group(id)? = sidebar { sidebar = .news }
    }

    // MARK: Fiches

    func copyMarkdown(_ fiche: FicheRecord) {
        let md = (try? MarkdownExporter(store: store, showRealNames: settings.showRealNames).markdown(for: fiche)) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    func exportFiche(_ fiche: FicheRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(fiche.question.prefix(80)).replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = (try? MarkdownExporter(store: store, showRealNames: settings.showRealNames)
            .markdown(for: fiche, includeSources: true)) ?? ""
        try? md.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Exporte un groupe (ou toute la base si nil) dans un dossier choisi.
    func exportFolder(conversationId: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Exporter ici")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let list = try store.fiches(.init(conversationId: conversationId))
            let n = try MarkdownExporter(store: store, showRealNames: settings.showRealNames)
                .export(list, to: url, includeSources: true)
            alert = L("\(n) fiches exportées.")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert = error.localizedDescription
        }
    }

    func setTheme(_ fiche: FicheRecord, name: String) {
        try? store.setTheme(ficheId: fiche.id, themeName: name)
    }

    func renameTheme(_ id: Int64, to name: String) { try? store.renameTheme(id, to: name) }

    func mergeTheme(_ id: Int64, into target: Int64) { try? store.mergeThemes(id, into: target) }

    func isMerged(_ fiche: FicheRecord) -> Bool {
        ((try? store.ficheThreads(fiche.id)) ?? []).contains { $0.mergedFromFicheId != nil }
    }

    func undoMerge(_ fiche: FicheRecord) {
        Task {
            isSyncing = true
            syncProgress = L("Séparation des fiches…")
            do { try await engine.undoMerge(ficheId: fiche.id, settings: settings) } catch { alert = error.localizedDescription }
            isSyncing = false
            syncProgress = nil
            reload()
        }
    }

    func sourceMessages(_ fiche: FicheRecord) -> [(author: String, date: Date, text: String)] {
        guard let messages = try? store.messages(ofFiche: fiche.id) else { return [] }
        var authors: [Int64: AuthorRecord] = [:]
        for c in Set(messages.map(\.conversationId)) { authors.merge((try? store.authors(in: c)) ?? [:]) { a, _ in a } }
        return messages.map { m in
            let a = authors[m.authorId]
            let name = settings.showRealNames ? (a?.displayName ?? a?.alias ?? "?") : (a?.alias ?? "?")
            let text = [m.mediaLabel.map { "[\($0)]" }, m.text].compactMap { $0 }.joined(separator: " ")
            return (name, m.sentAt, text)
        }
    }

    // MARK: Système

    private func applyLoginItem() {
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert = L("Lancement à l'ouverture de session impossible : \(error.localizedDescription)")
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Une seule notification par synchronisation, jamais une par fiche (brief § 7.4).
    private func notify(_ s: SyncSummary) {
        guard settings.notificationsEnabled, s.error == nil, s.fichesCreated + s.fichesUpdated > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "DistiX"
        content.body = L("\(s.fichesCreated) nouvelles questions, \(s.fichesUpdated) fiches mises à jour")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
