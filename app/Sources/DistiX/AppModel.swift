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
    var reviewFilter: Store.ReviewFilter = .kept { didSet { reloadFiches() } }
    var showTour = false
    var editingTheme: ThemeDraft?
    /// Modèles installés dans Ollama (mis à jour à l'ouverture et dans les réglages).
    var localModels: [String] = []
    var ollamaRunning = false
    var searchText = "" { didSet { reloadFiches() } }
    var fiches: [FicheRecord] = []
    var opportunities: [OpportunityRecord] = []
    /// Élément sélectionné : identifiant de fiche, ou « o-<id> » pour une opportunité.
    var selectedFicheId: String? { didSet { openedItem() } }
    var editingGoal: ConversationRecord?
    var isSyncing = false
    var syncProgress: String?
    var lastRun: SyncRunRecord?
    var alert: String?
    var showOnboarding = false
    var showGroups = false
    var confirmReprocess: ConversationRecord?
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
        Task { await refreshLocalModels() }
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
        var q = Store.FicheQuery(status: statusFilter, review: reviewFilter)
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
        // Opportunités (mode veille) : pas de thème, pas de statut.
        var opps: [OpportunityRecord] = []
        if q.themeId == nil && statusFilter == nil && reviewFilter == .kept {
            opps = (try? store.opportunities(conversationId: q.conversationId, unreadOnly: q.unreadOnly, search: q.search)) ?? []
            if q.unreadOnly {
                let kept = sessionRead.compactMap(Self.opportunityId).compactMap { try? store.opportunity($0) }
                    .filter { o in !opps.contains { $0.id == o.id } }
                opps = (opps + kept).sorted { $0.sentAt > $1.sentAt }
            }
        }
        opportunities = opps
    }

    static func itemId(_ o: OpportunityRecord) -> String { "o-\(o.id!)" }
    static func opportunityId(_ itemId: String) -> Int64? {
        itemId.hasPrefix("o-") ? Int64(itemId.dropFirst(2)) : nil
    }

    var selectedOpportunity: OpportunityRecord? {
        selectedFicheId.flatMap(Self.opportunityId).flatMap { id in opportunities.first { $0.id == id } ?? (try? store.opportunity(id)) }
    }

    var selectedFiche: FicheRecord? {
        guard let id = selectedFicheId, Self.opportunityId(id) == nil else { return nil }
        return fiches.first { $0.id == id } ?? (try? store.fiche(id))
    }

    private func openedItem() {
        guard let id = selectedFicheId else { return }
        if let oid = Self.opportunityId(id) {
            guard let o = try? store.opportunity(oid), o.isUnread else { return }
            sessionRead.insert(id)
            try? store.markOpportunityRead(oid, read: true)
        } else {
            guard let f = try? store.fiche(id), f.isUnread else { return }
            sessionRead.insert(id)
            try? store.markRead(id, read: true)
        }
    }

    func markUnread(_ id: String) { markUnread(itemId: id) }

    func markUnread(itemId id: String) {
        sessionRead.insert(id)
        if let oid = Self.opportunityId(id) { try? store.markOpportunityRead(oid, read: false) }
        else { try? store.markRead(id, read: false) }
    }

    // MARK: Tri, modèles, thèmes

    /// Valide ou écarte la fiche, puis passe à la suivante de la liste.
    func review(_ fiche: FicheRecord, _ state: ReviewState?) {
        let index = fiches.firstIndex { $0.id == fiche.id }
        try? store.setReview(fiche.id, fiche.review == state ? nil : state)
        if fiche.review != state, let index, index + 1 < fiches.count {
            selectedFicheId = fiches[index + 1].id
        }
    }

    struct ModelChoice: Identifiable, Hashable {
        var id: String { "\(provider.rawValue):\(model)" }
        let provider: ProviderKind
        let model: String
        let label: String
    }

    /// Modèles proposés pour régénérer une fiche, selon ce qui est disponible sur ce Mac.
    var modelChoices: [ModelChoice] {
        var out: [ModelChoice] = []
        if !ClaudeCodeProvider.candidates(custom: settings.claudePath).isEmpty {
            out += [("haiku", "Haiku (rapide)"), ("sonnet", "Sonnet (équilibré)"), ("opus", "Opus (le plus capable)")]
                .map { ModelChoice(provider: .claudeCode, model: $0.0, label: "Claude Code · \($0.1)") }
        }
        if Keychain.get(ProviderFactory.anthropicKeyAccount)?.isEmpty == false {
            out += [("claude-haiku-4-5", "Haiku 4.5"), ("claude-sonnet-5", "Sonnet 5"), ("claude-opus-5", "Opus 5")]
                .map { ModelChoice(provider: .anthropic, model: $0.0, label: "API Anthropic · \($0.1)") }
        }
        out += localModels.map { ModelChoice(provider: .openAICompatible, model: $0, label: L("Local · \($0)")) }
        return out
    }

    func regenerate(_ fiche: FicheRecord, with choice: ModelChoice) {
        Task {
            isSyncing = true
            syncProgress = L("Régénération avec \(choice.label)…")
            var s = settings
            if choice.provider == .openAICompatible { s.openAIBaseURL = OllamaClient().openAIBaseURL.absoluteString }
            do { try await engine.regenerate(ficheId: fiche.id, provider: choice.provider, model: choice.model, settings: s) }
            catch { alert = error.localizedDescription }
            isSyncing = false
            syncProgress = nil
            reload()
        }
    }

    func refreshLocalModels() async {
        let client = OllamaClient()
        ollamaRunning = await client.isRunning()
        localModels = ollamaRunning ? ((try? await client.installedModels()) ?? []) : []
    }

    struct ThemeDraft: Identifiable {
        let id = UUID()
        var themeId: Int64?
        var conversationId: String
        var name: String
        var objective: String
    }

    func newTheme(in conversationId: String) {
        editingTheme = ThemeDraft(themeId: nil, conversationId: conversationId, name: "", objective: "")
    }

    func edit(_ theme: ThemeRecord) {
        editingTheme = ThemeDraft(themeId: theme.id, conversationId: theme.conversationId, name: theme.name,
                                  objective: theme.objective ?? "")
    }

    func saveTheme(_ draft: ThemeDraft) {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? store.saveTheme(id: draft.themeId, conversationId: draft.conversationId, name: draft.name, objective: draft.objective)
    }

    // MARK: Objectif du groupe et veille

    func saveGoal(_ c: ConversationRecord, mode: GroupMode, focus: String, language: String?, reprocess: Bool) {
        try? store.setGoal(c.id, mode: mode, focus: focus)
        try? store.setLanguage(c.id, language: language)
        if reprocess, let updated = try? store.conversation(c.id) { self.reprocess(updated) }
    }

    func translate(_ fiche: FicheRecord, to language: String) {
        Task {
            isSyncing = true
            syncProgress = L("Traduction de la fiche…")
            do { try await engine.translate(ficheId: fiche.id, to: language, settings: settings) } catch { alert = error.localizedDescription }
            isSyncing = false
            syncProgress = nil
            reload()
        }
    }

    func authorName(ofMessage id: Int64) -> String {
        guard let m = try? store.message(id), let a = try? store.author(m.authorId) else { return "?" }
        return a.displayName ?? a.alias
    }

    /// Nom réel et numéro de l'auteur : en veille, le but est de pouvoir le contacter.
    func authorContact(ofMessage id: Int64) -> (name: String, phone: String?) {
        guard let m = try? store.message(id), let a = try? store.author(m.authorId) else { return ("?", nil) }
        return (a.displayName ?? a.alias, a.phone)
    }

    func context(ofOpportunity o: OpportunityRecord) -> [(author: String, date: Date, text: String, isTarget: Bool)] {
        guard let m = try? store.message(o.messageId), let around = try? store.messagesAround(m, before: 3, after: 3) else { return [] }
        let authors = (try? store.authors(in: o.conversationId)) ?? [:]
        return around.map { x in
            let a = authors[x.authorId]
            let text = [x.mediaLabel.map { "[\($0)]" }, x.text].compactMap { $0 }.joined(separator: " ")
            return (a?.displayName ?? a?.alias ?? "?", x.sentAt, text, x.id == m.id)
        }
    }

    func copyOpportunity(_ o: OpportunityRecord) {
        guard let m = try? store.message(o.messageId) else { return }
        let contact = authorContact(ofMessage: o.messageId)
        let text = "\(o.summary)\n\(contact.name)\(contact.phone.map { " · \($0)" } ?? "")\n\n\(m.text ?? "")"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Ouvre une conversation privée WhatsApp avec ce numéro.
    func writePrivately(to phone: String) {
        // Uniquement par WhatsApp Desktop : jamais de numéro tiers dans une adresse web.
        let digits = phone.filter(\.isNumber)
        guard let url = URL(string: "whatsapp://send?phone=\(digits)"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            alert = L("WhatsApp Desktop ne répond pas à l'ouverture d'une conversation. Numéro copié dans le presse-papiers.")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(phone, forType: .string)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openWhatsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func markAllRead() {
        try? store.markAllRead()
    }

    func usableCount(_ id: String) -> Int { (try? store.usableMessageCount(in: id)) ?? 0 }

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
        if settings.openWhatsAppBeforeSync { await openWhatsAppAndWait() }
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

    /// Vérifie chaque minute quels groupes sont dus, selon leur fréquence propre ou
    /// la fréquence globale, et ne synchronise que ceux-là.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncDueGroups() }
        }
    }

    func syncDueGroups() async {
        guard settings.onboardingDone, !isSyncing else { return }
        let due = ((try? store.selectedConversations()) ?? [])
            .filter { $0.isDue(globalIntervalHours: settings.syncIntervalHours) }.map(\.id)
        if !due.isEmpty { await sync(only: due) }
    }

    func setSyncInterval(_ c: ConversationRecord, hours: Double?) {
        try? store.setSyncInterval(c.id, hours: hours)
    }

    static let intervalChoices: [(hours: Double, label: String)] = [
        (0.25, L("Toutes les 15 minutes")), (0.5, L("Toutes les 30 minutes")), (1, L("Toutes les heures")),
        (3, L("Toutes les 3 heures")), (6, L("Toutes les 6 heures")), (12, L("Toutes les 12 heures")),
        (24, L("Une fois par jour")),
    ]

    static func intervalLabel(_ hours: Double) -> String {
        intervalChoices.first { $0.hours == hours }?.label ?? L("Toutes les \(hours.formatted()) h")
    }

    func startAfterOnboarding() {
        settings.onboardingDone = true
        showOnboarding = false
        scheduleTimer()
        syncNow()
    }

    private func openWhatsAppAndWait() async {
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

    /// Supprime les données d'un groupe et le retraite depuis sa profondeur d'historique.
    func reprocess(_ c: ConversationRecord) {
        deleteData(of: c.id)
        Task { await sync(only: [c.id]) }
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
    func exportFolder(conversationId: String?, onlyValidated: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Exporter ici")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let list = try store.fiches(.init(conversationId: conversationId, review: onlyValidated ? .validated : .kept))
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
        guard settings.notificationsEnabled, s.error == nil, s.fichesCreated + s.fichesUpdated + s.opportunities > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "DistiX"
        var parts: [String] = []
        if s.opportunities > 0 { parts.append(L("\(s.opportunities) opportunités")) }
        if s.fichesCreated > 0 { parts.append(L("\(s.fichesCreated) nouvelles questions")) }
        if s.fichesUpdated > 0 { parts.append(L("\(s.fichesUpdated) fiches mises à jour")) }
        content.body = parts.joined(separator: ", ")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
