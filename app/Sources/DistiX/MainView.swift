import DistiXCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            FicheListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            if let fiche = model.selectedFiche {
                FicheDetailView(fiche: fiche)
            } else {
                ContentUnavailableView(L("Aucune fiche sélectionnée"), systemImage: "text.book.closed",
                                       description: Text(L("Choisissez une fiche dans la liste.")))
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(L("Rechercher dans toutes les fiches")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showGroups = true } label: { Label(L("Groupes"), systemImage: "person.3") }
                    .help(L("Ajouter ou retirer des groupes"))
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.syncProgress ?? "").font(.caption).lineLimit(1).frame(maxWidth: 320)
                    }
                } else {
                    Button { model.syncNow() } label: { Label(L("Synchroniser"), systemImage: "arrow.clockwise") }
                        .help(L("Synchroniser maintenant"))
                }
            }
        }
        .sheet(isPresented: $model.showGroups) {
            GroupsSheet().environment(model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environment(model).interactiveDismissDisabled()
        }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: ThemeRecord?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label(L("Nouveautés"), systemImage: "sparkles")
                .badge(model.totalUnread)
                .tag(SidebarItem.news)
            Section {
                ForEach(model.selectedConversations) { c in
                    DisclosureGroup {
                        ForEach(model.themes[c.id] ?? []) { t in
                            Text(t.name)
                                .badge(model.themeUnread[t.id!] ?? 0)
                                .tag(SidebarItem.theme(c.id, t.id!))
                                .contextMenu { themeMenu(t, in: c.id) }
                        }
                    } label: {
                        Label(c.name, systemImage: c.syncIntervalHours == nil ? "person.3" : "person.3.sequence")
                            .badge(model.unread[c.id] ?? 0)
                            .tag(SidebarItem.group(c.id))
                            .contextMenu {
                                Button(L("Gérer les groupes…")) { model.showGroups = true }
                                Button(L("Exporter ce groupe…")) { model.exportFolder(conversationId: c.id) }
                                Button(L("Tout marquer comme lu")) { try? model.store.markAllRead(conversationId: c.id) }
                                Menu(L("Fréquence de synchro")) {
                                    Button((c.syncIntervalHours == nil ? "✓ " : "") + L("Par défaut (\(AppModel.intervalLabel(model.settings.syncIntervalHours).lowercased()))")) {
                                        model.setSyncInterval(c, hours: nil)
                                    }
                                    Divider()
                                    ForEach(AppModel.intervalChoices, id: \.hours) { choice in
                                        Button((c.syncIntervalHours == choice.hours ? "✓ " : "") + choice.label) {
                                            model.setSyncInterval(c, hours: choice.hours)
                                        }
                                    }
                                }
                                Divider()
                                Button(L("Retraiter ce groupe…")) { model.confirmReprocess = c }
                            }
                    }
                }
                Button { model.showGroups = true } label: {
                    Label(model.selectedConversations.isEmpty ? L("Choisir des groupes…") : L("Ajouter ou retirer des groupes…"),
                          systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } header: {
                Text(L("Groupes"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let run = model.lastRun, !model.isSyncing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Dernière synchro : \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"))
                    if run.error != nil { Text(L("En échec — voir Réglages")).foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(L("Retraiter ce groupe ?"),
                            isPresented: Binding(get: { model.confirmReprocess != nil }, set: { if !$0 { model.confirmReprocess = nil } })) {
            Button(L("Supprimer ses fiches et tout retraiter"), role: .destructive) {
                if let c = model.confirmReprocess { model.reprocess(c) }
            }
        } message: {
            Text(L("Les fiches de ce groupe sont supprimées puis recréées à partir des messages, avec les réglages actuels. Utile après un changement de consignes ou de profondeur d'historique."))
        }
        .alert(L("Renommer le thème"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Nom"), text: $newName)
            Button(L("Renommer")) { if let t = renaming { model.renameTheme(t.id!, to: newName) }; renaming = nil }
            Button(L("Annuler"), role: .cancel) { renaming = nil }
        } message: {
            Text(L("Si un thème porte déjà ce nom, les deux seront fusionnés."))
        }
    }

    @ViewBuilder
    private func themeMenu(_ t: ThemeRecord, in conversationId: String) -> some View {
        Button(L("Renommer…")) { newName = t.name; renaming = t }
        Menu(L("Fusionner dans")) {
            ForEach((model.themes[conversationId] ?? []).filter { $0.id != t.id }) { other in
                Button(other.name) { model.mergeTheme(t.id!, into: other.id!) }
            }
        }
    }
}

struct FicheListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(model.fiches, selection: $model.selectedFicheId) { f in
            FicheRow(fiche: f).tag(f.id)
        }
        .overlay {
            if model.fiches.isEmpty {
                if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else if model.sidebar == .news {
                    ContentUnavailableView(L("Rien de nouveau"), systemImage: "checkmark.circle",
                                           description: Text(L("Les nouvelles questions et les fiches mises à jour apparaîtront ici.")))
                } else if case .group(let id)? = model.sidebar, model.usableCount(id) == 0,
                          model.conversations.first(where: { $0.id == id })?.lastSyncedAt != nil {
                    ContentUnavailableView(L("Aucun message exploitable"), systemImage: "text.badge.xmark",
                                           description: Text(L("Ce groupe ne contient, sur ce Mac et pour la période choisie, que des événements ou des entrées vides (appels, notifications, messages supprimés).")))
                } else {
                    ContentUnavailableView(L("Aucune fiche"), systemImage: "tray",
                                           description: Text(L("Les fiches apparaissent après la synchronisation, quand des questions ou des informations utiles ont été trouvées.")))
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Picker(L("Statut"), selection: $model.statusFilter) {
                    Text(L("Tous les statuts")).tag(FicheStatus?.none)
                    ForEach(FicheStatus.allCases, id: \.self) { s in
                        Text(MarkdownExporter.statusLabel(s)).tag(FicheStatus?.some(s))
                    }
                }
                .pickerStyle(.menu)
                if model.sidebar == .news && !model.fiches.isEmpty {
                    Button(L("Tout marquer comme lu")) { model.markAllRead() }
                }
            }
        }
    }

    private var title: String {
        if !model.searchText.isEmpty { return L("Recherche") }
        switch model.sidebar {
        case .news, nil: return L("Nouveautés")
        case .group(let id): return model.conversationName(id)
        case .theme(_, let t): return model.themeName(t)
        }
    }
}

struct FicheRow: View {
    @Environment(AppModel.self) private var model
    let fiche: FicheRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if fiche.isUnread {
                    Text(fiche.readState == .updated ? L("mis à jour") : L("nouveau"))
                        .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(fiche.readState == .updated ? Color.orange.opacity(0.2) : Color.accentColor.opacity(0.2),
                                    in: Capsule())
                }
                Text(fiche.question).font(fiche.isUnread ? .body.bold() : .body).lineLimit(3)
            }
            HStack(spacing: 8) {
                StatusBadge(status: fiche.status)
                Text(model.themeName(fiche.themeId)).foregroundStyle(.secondary)
                Spacer()
                Text(fiche.lastMessageAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }
}

struct StatusBadge: View {
    let status: FicheStatus
    var body: some View {
        Text(MarkdownExporter.statusLabel(status))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .repondue: return .green
        case .debattue: return .orange
        case .sans_reponse: return .gray
        }
    }
}

/// Ajout et retrait de groupes après l'accueil.
struct GroupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var depth: HistoryDepth = .three
    @State private var initial: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Groupes suivis")).font(.title2.bold())
            Text(L("Cochez les groupes à transformer en fiches. La profondeur d'historique s'applique aux groupes que vous cochez maintenant ; l'élargir pour un groupe déjà suivi récupère les messages plus anciens."))
                .font(.callout).foregroundStyle(.secondary)
            GroupPicker(depth: $depth, confirmUnselect: true)
            HStack {
                Button(L("Actualiser la liste")) { Task { _ = await model.refreshGroups() } }
                Spacer()
                Button(L("Fermer")) { dismiss() }
                Button(L("Fermer et synchroniser")) {
                    dismiss()
                    model.syncNow()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedConversations.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .task { _ = await model.refreshGroups() }
    }
}
