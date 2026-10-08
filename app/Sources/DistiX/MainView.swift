import DistiXCore
import SwiftUI

/// Fenêtre principale : barre latérale flottante, liste, et fiche dans une carte blanche.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView().frame(width: 244)
            FicheListView().frame(width: 340)
            DetailPane()
        }
        .background(DS.window)
        .ignoresSafeArea()
        .tint(DS.accent)
        .background(WindowAccessor { window in
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            TrafficLightPositioner.shared.attach(to: window)
        })
        .sheet(isPresented: $model.showTour) { FeatureTour(onFinish: { model.showTour = false }) }
        .sheet(item: $model.editingTheme) { draft in ThemeSheet(draft: draft).environment(model) }
        .sheet(item: $model.editingGoal) { c in
            GroupGoalSheet(conversation: c).environment(model)
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

/// Carte blanche de droite : la fiche, l'opportunité, ou un état vide.
struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let o = model.selectedOpportunity {
                OpportunityDetailView(opportunity: o).id(AppModel.itemId(o))
            } else if let fiche = model.selectedFiche {
                FicheDetailView(fiche: fiche).id(fiche.id)
            } else {
                VStack(spacing: 8) {
                    AppIconView(size: 56).opacity(0.9)
                    Text(L("Aucune fiche sélectionnée")).font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.text).padding(.top, 8)
                    Text(L("Choisissez une fiche dans la liste.")).font(.system(size: 13)).foregroundStyle(DS.text4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
        .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8))
    }
}

// MARK: Barre latérale

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: ThemeRecord?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            RoundSearchField(prompt: L("Rechercher"), text: $model.searchText)
                .padding(.top, 34)
                .help(L("Rechercher dans toutes les fiches"))
            VStack(spacing: 2) {
                SidebarRow(title: L("Nouveautés"), count: model.totalUnread, selected: isSelected(.news)) { select(.news) }
                SidebarRow(title: L("Validées"), count: model.validatedCount, selected: isSelected(.validated)) { select(.validated) }
            }
            .padding(.top, 14)
            Text(L("Groupes")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text4)
                .padding(EdgeInsets(top: 18, leading: 10, bottom: 6, trailing: 10))
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(model.selectedConversations.enumerated()), id: \.element.id) { index, c in
                        groupRows(c, index: index)
                    }
                    Button { model.showGroups = true } label: {
                        HStack(spacing: 9) {
                            Text("+").frame(width: 8)
                            Text(model.selectedConversations.isEmpty ? L("Choisir des groupes…") : L("Gérer les groupes…"))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13)).foregroundStyle(DS.text4)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help(L("Ajouter ou retirer des groupes"))
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(DS.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
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

    private func isSelected(_ item: SidebarItem) -> Bool {
        model.searchText.isEmpty && model.sidebar == item
    }

    private func select(_ item: SidebarItem) {
        model.searchText = ""
        model.sidebar = item
    }

    /// Les thèmes ne sont dépliés que pour le groupe ouvert.
    private func isExpanded(_ c: ConversationRecord) -> Bool {
        switch model.sidebar {
        case .group(let id)?, .theme(let id, _)?: return id == c.id && c.mode != .watch
        default: return false
        }
    }

    @ViewBuilder
    private func groupRows(_ c: ConversationRecord, index: Int) -> some View {
        let selected = isSelected(.group(c.id))
        SidebarRow(title: c.name, count: model.unread[c.id] ?? 0, selected: selected,
                   dot: c.mode == .watch ? DS.orangeDot : DS.groupDots[index % DS.groupDots.count],
                   squareDot: c.mode == .watch) { select(.group(c.id)) }
            .contextMenu { groupMenu(c) }
            .help(c.mode == .watch ? L("Groupe en veille") : c.name)
        if isExpanded(c) {
            ForEach(model.themes[c.id] ?? []) { t in
                SidebarRow(title: t.name, count: model.themeUnread[t.id!] ?? 0,
                           selected: isSelected(.theme(c.id, t.id!)), indented: true) { select(.theme(c.id, t.id!)) }
                    .contextMenu { themeMenu(t, in: c.id) }
                    .help(t.objective ?? "")
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ c: ConversationRecord) -> some View {
        Button(L("Objectif du groupe…")) { model.editingGoal = c }
        if c.mode == .knowledge {
            Button(L("Nouveau thème…")) { model.newTheme(in: c.id) }
        }
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

    @ViewBuilder
    private func themeMenu(_ t: ThemeRecord, in conversationId: String) -> some View {
        Button(L("Modifier le thème…")) { model.edit(t) }
        Button(L("Supprimer le thème"), role: .destructive) { model.deleteTheme(t.id!) }
        Button(L("Renommer…")) { newName = t.name; renaming = t }
        Menu(L("Fusionner dans")) {
            ForEach((model.themes[conversationId] ?? []).filter { $0.id != t.id }) { other in
                Button(other.name) { model.mergeTheme(t.id!, into: other.id!) }
            }
        }
    }

    // MARK: Pied : état de la synchro

    private var footer: some View {
        HStack(alignment: .center, spacing: 6) {
            syncStatus.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button(L("Exporter les fiches validées…")) { model.exportFolder(conversationId: nil, onlyValidated: true) }
                Button(L("Exporter toute la base…")) { model.exportFolder(conversationId: nil) }
                Divider()
                Button(L("Réglages…")) { openSettings() }
                Button(L("Découvrir DistiX")) { model.showTour = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .handCursor()
            .foregroundStyle(DS.text2)
            .help(L("Exporter, réglages, aide"))
            .accessibilityLabel(L("Plus"))
            Button { model.syncNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text2)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor(!model.isSyncing)
            .disabled(model.isSyncing)
            .help(L("Synchroniser maintenant"))
            .accessibilityLabel(L("Synchroniser"))
        }
        .font(.system(size: 11))
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 2, trailing: 6))
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let since = model.readingSince {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                if ctx.date.timeIntervalSince(since) > 5 {
                    Text(L("En attente de WhatsApp : si macOS demande d'autoriser DistiX à accéder aux données d'autres apps, cliquez sur « Autoriser »."))
                        .foregroundStyle(DS.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    progressLine(model.syncProgress ?? L("Lecture de WhatsApp…"))
                }
            }
        } else if let text = model.busyAction ?? (model.isSyncing ? model.syncProgress : nil) {
            progressLine(text)
        } else if let run = model.lastRun {
            if let end = run.finishedAt, run.error == nil {
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    Text(L("Synchronisé \(Self.relative(end, now: ctx.date))")).foregroundStyle(DS.text4)
                        .help(model.lastSyncText(run))
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.lastSyncText(run)).foregroundStyle(DS.text4)
                    if run.error != nil && run.finishedAt != nil { Text(L("En échec — voir Réglages")).foregroundStyle(DS.red) }
                }
            }
        } else {
            Text(L("Jamais synchronisé")).foregroundStyle(DS.text4)
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).foregroundStyle(DS.text3).lineLimit(2).truncationMode(.middle)
        }
        .help(text)
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return L("à l'instant") }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// Ligne de la barre latérale : pastille éventuelle, titre, compteur.
struct SidebarRow: View {
    let title: String
    var count = 0
    var selected = false
    var dot: Color?
    var squareDot = false
    var indented = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let dot { StatusDot(color: selected ? .white : dot, size: 8, square: squareDot) }
                Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 {
                    if selected {
                        Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 6).background(.white.opacity(0.25), in: Capsule())
                    } else {
                        Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text4)
                    }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.white : (indented || dot == nil ? DS.text2 : DS.text))
            .padding(EdgeInsets(top: indented ? 5 : 7, leading: indented ? 27 : 10, bottom: indented ? 5 : 7, trailing: 10))
            .background(selected ? DS.accent : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Liste

struct FicheListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.fiches.isEmpty && model.opportunities.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if !model.opportunities.isEmpty {
                                if !model.fiches.isEmpty { CapsLabel(L("Opportunités")).padding(.horizontal, 14).padding(.top, 4) }
                                ForEach(model.opportunities) { o in
                                    let id = AppModel.itemId(o)
                                    row(id: id) { OpportunityRow(opportunity: o, selected: model.selectedFicheId == id) }
                                }
                            }
                            if !model.fiches.isEmpty {
                                if !model.opportunities.isEmpty { CapsLabel(L("Fiches")).padding(.horizontal, 14).padding(.top, 10) }
                                ForEach(model.fiches) { f in
                                    row(id: f.id) { FicheRow(fiche: f, selected: model.selectedFicheId == f.id) }
                                }
                            }
                        }
                        .padding(4)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1, proxy: proxy) }
                    .onKeyPress(.upArrow) { move(-1, proxy: proxy) }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func row<Content: View>(id: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            model.selectedFicheId = id
            focused = true
        } label: { content() }
            .buttonStyle(.plain)
            .handCursor()
            .id(id)
            .accessibilityAddTraits(model.selectedFicheId == id ? .isSelected : [])
    }

    private var itemIds: [String] { model.opportunities.map(AppModel.itemId) + model.fiches.map(\.id) }

    private func move(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = itemIds
        guard !ids.isEmpty else { return .ignored }
        let current = model.selectedFicheId.flatMap { ids.firstIndex(of: $0) }
        let next = min(max((current ?? (delta > 0 ? -1 : ids.count)) + delta, 0), ids.count - 1)
        model.selectedFicheId = ids[next]
        proxy.scrollTo(ids[next])
        return .handled
    }

    // MARK: En-tête et filtres

    private var watchGroup: ConversationRecord? {
        guard model.searchText.isEmpty, case .group(let id)? = model.sidebar else { return nil }
        return model.conversations.first { $0.id == id && $0.mode == .watch }
    }

    private var header: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.4).foregroundStyle(DS.text)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if model.sidebar == .news && model.searchText.isEmpty && !(model.fiches.isEmpty && model.opportunities.isEmpty) {
                    Button(L("Tout marquer comme lu")) { model.markAllRead() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.accent).handCursor()
                }
            }
            if let c = watchGroup {
                let focus = (c.focus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                Text(focus.isEmpty ? L("Veille") : L("Veille · \(focus)"))
                    .font(.system(size: 12)).foregroundStyle(DS.text4).lineLimit(2).padding(.top, 4)
            } else {
                HStack(spacing: 6) {
                    if model.sidebar != .validated || !model.searchText.isEmpty {
                        chip(L("Toutes"), .kept)
                        chip(L("À trier"), .toReview)
                        chip(L("Validées"), .validated)
                        if model.reviewFilter == .discarded { chip(L("Écartées"), .discarded) }
                    }
                    Menu {
                        Picker(L("Statut"), selection: $model.statusFilter) {
                            Text(L("Tous les statuts")).tag(FicheStatus?.none)
                            ForEach(FicheStatus.allCases, id: \.self) { s in
                                Text(MarkdownExporter.statusLabel(s)).tag(FicheStatus?.some(s))
                            }
                        }
                        .pickerStyle(.inline).labelsHidden()
                        if model.sidebar != .validated {
                            Divider()
                            Toggle(L("Afficher les fiches écartées"), isOn: Binding(
                                get: { model.reviewFilter == .discarded },
                                set: { model.reviewFilter = $0 ? .discarded : .kept }))
                        }
                    } label: {
                        Text((model.statusFilter.map(MarkdownExporter.statusLabel) ?? L("Statut")) + " ⌄")
                            .font(.system(size: 12)).foregroundStyle(model.statusFilter == nil ? DS.text2 : DS.accentInk)
                            .padding(.horizontal, 10).padding(.vertical, 4).contentShape(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .handCursor()
                    .background(model.statusFilter == nil ? DS.fill : DS.accentTint, in: Capsule())
                    .accessibilityLabel(L("Statut"))
                }
                .padding(.top, 10)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 14, bottom: 12, trailing: 14))
    }

    private func chip(_ label: String, _ filter: Store.ReviewFilter) -> some View {
        Button(label) { model.reviewFilter = (model.reviewFilter == filter && filter == .discarded) ? .kept : filter }
            .buttonStyle(ChipStyle(selected: model.reviewFilter == filter))
    }

    private var title: String {
        if !model.searchText.isEmpty { return L("Recherche") }
        switch model.sidebar {
        case .news, nil: return L("Nouveautés")
        case .validated: return L("Validées")
        case .group(let id): return model.conversationName(id)
        case .theme(_, let t): return model.themeName(t)
        }
    }

    // MARK: États vides

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            EmptyNote(symbol: "magnifyingglass", title: L("Aucun résultat"),
                      text: L("Aucune fiche ne correspond à « \(model.searchText) »."))
        } else if model.sidebar == .news {
            EmptyNote(symbol: "checkmark.circle", title: L("Rien de nouveau"),
                      text: L("Les nouvelles questions et les fiches mises à jour apparaîtront ici."))
        } else if model.sidebar == .validated {
            EmptyNote(symbol: "checkmark.seal", title: L("Aucune fiche validée"),
                      text: L("Validez les fiches utiles : elles formeront votre base, exportable en Markdown."))
        } else if let c = watchGroup {
            EmptyNote(symbol: "binoculars", title: L("Aucune opportunité pour l'instant"),
                      text: (c.focus ?? "").isEmpty
                        ? L("Renseignez vos critères : clic droit sur le groupe, « Objectif du groupe… ».")
                        : L("Les messages qui correspondent à vos critères apparaîtront ici."))
        } else if case .group(let id)? = model.sidebar, model.usableCount(id) == 0,
                  model.conversations.first(where: { $0.id == id })?.lastSyncedAt != nil {
            EmptyNote(symbol: "text.badge.xmark", title: L("Aucun message exploitable"),
                      text: L("Ce groupe ne contient, sur ce Mac et pour la période choisie, que des événements ou des entrées vides (appels, notifications, messages supprimés)."))
        } else {
            EmptyNote(symbol: "tray", title: L("Aucune fiche"),
                      text: L("Les fiches apparaissent après la synchronisation, quand des questions ou des informations utiles ont été trouvées."))
        }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(DS.text4)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).padding(.top, 4)
            Text(text).font(.system(size: 12.5)).foregroundStyle(DS.text4).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
    }
}

/// Fond d'une ligne de liste : carte blanche quand elle est sélectionnée.
struct ListCard: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.card)
                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FicheRow: View {
    @Environment(AppModel.self) private var model
    let fiche: FicheRecord
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if fiche.isUnread {
                    Text(fiche.readState == .updated ? L("Mis à jour") : L("Nouveau"))
                        .fontWeight(.semibold).foregroundStyle(fiche.readState == .updated ? DS.orange : DS.accent)
                    Text("·")
                }
                Text(model.themeName(fiche.themeId)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(DS.listDate(fiche.lastMessageAt))
            }
            .font(.system(size: 11)).foregroundStyle(DS.text4)
            Text(fiche.decodedTranslation?.question ?? fiche.question)
                .font(.system(size: 13.5, weight: .semibold)).lineSpacing(1.5).lineLimit(4)
                .foregroundStyle(fiche.review == .discarded ? DS.text4 : DS.text)
                .strikethrough(fiche.review == .discarded)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                StatusDot(color: DS.statusDot(fiche.status))
                Text(MarkdownExporter.statusLabel(fiche.status))
                if fiche.review == .validated {
                    Text("·")
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.green)
                    Text(L("Validée")).foregroundStyle(DS.green)
                }
            }
            .font(.system(size: 11)).foregroundStyle(DS.text3)
        }
        .modifier(ListCard(selected: selected))
    }
}

extension DS {
    static func statusDot(_ status: FicheStatus) -> Color {
        switch status {
        case .repondue: return greenDot
        case .debattue: return orangeDot
        case .sans_reponse: return greyDot
        }
    }

    /// « Aujourd'hui », « Hier », sinon « 11 sept. ».
    static func listDate(_ date: Date, time: Bool = false) -> String {
        let calendar = Calendar.current
        let clock = time ? " " + date.formatted(date: .omitted, time: .shortened) : ""
        if calendar.isDateInToday(date) { return L("Aujourd'hui") + clock }
        if calendar.isDateInYesterday(date) { return L("Hier") + clock }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let style: Date.FormatStyle = sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year()
        return date.formatted(style.locale(Locale(identifier: "fr_FR"))) + clock
    }
}

// MARK: Feuilles

/// Titre et explication en tête d'une feuille.
struct SheetHeader: View {
    let title: String
    var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.4).foregroundStyle(DS.text)
            if let text {
                Text(text).font(.system(size: 13)).lineSpacing(2).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Ajout et retrait de groupes après l'accueil.
struct GroupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var depth: HistoryDepth = .three

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: L("Groupes suivis"),
                        text: L("Cochez les groupes à transformer en fiches. L'historique choisi s'applique aux groupes que vous cochez maintenant ; l'élargir pour un groupe déjà suivi récupère les messages plus anciens."))
            GroupPicker(depth: $depth, confirmUnselect: true, showGoal: true)
            HStack(spacing: 8) {
                Button(L("Actualiser la liste")) { Task { _ = await model.refreshGroups() } }.buttonStyle(.pillLink)
                Spacer()
                Button(L("Fermer")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(L("Fermer et synchroniser")) {
                    dismiss()
                    model.syncNow()
                }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedConversations.isEmpty)
            }
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 22, trailing: 28))
        .frame(width: 640, height: 560)
        .dsSheet()
        .task { _ = await model.refreshGroups() }
        .sheet(item: Binding(get: { model.editingGoal }, set: { model.editingGoal = $0 })) { c in
            GroupGoalSheet(conversation: c).environment(model)
        }
    }
}

/// Zone de saisie longue dans une carte blanche.
struct CardEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14)).lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 11).padding(.vertical, 12)
            .frame(minHeight: minHeight)
            .dsCard(outline: DS.hairline)
    }
}

/// Création ou modification d'un thème : nom et objectif.
struct ThemeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: AppModel.ThemeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: draft.themeId == nil ? L("Nouveau thème") : L("Modifier le thème"))
            HStack(spacing: 12) {
                Text(L("Nom")).font(.system(size: 13)).foregroundStyle(DS.text4).frame(width: 44, alignment: .leading)
                TextField(L("Nom du thème"), text: $draft.name).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .dsCard()
            VStack(alignment: .leading, spacing: 6) {
                CapsLabel(L("Objectif du thème"))
                Text(L("Décrivez précisément ce que ce thème doit rassembler et ce qui vous intéresse. L'IA s'en sert pour classer les fiches et pour mettre en avant ce qui sert cet objectif."))
                    .font(.system(size: 13)).lineSpacing(2).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            CardEditor(text: $draft.objective, minHeight: 110)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Exemple : « Réglages et matériel de parapente : noms exacts des modèles, tailles, réglages des trims et freins, avec les chiffres donnés. »"))
                Text(L("S'applique aux prochaines fiches ; « Retraiter ce groupe » reclasse les fiches existantes."))
            }
            .font(.system(size: 12)).lineSpacing(2).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let id = draft.themeId {
                    Button(L("Supprimer le thème")) { model.deleteTheme(id); dismiss() }
                        .buttonStyle(PillButtonStyle(kind: .destructiveLink, compact: true))
                }
                Spacer()
                Button(L("Annuler")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(L("Enregistrer")) { model.saveTheme(draft); dismiss() }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 22, trailing: 28))
        .frame(width: 560)
        .dsSheet()
    }
}
