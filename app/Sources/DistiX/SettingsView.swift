import DistiXCore
import SwiftUI

/// Réglages : onglets en pilule dans la barre de titre, formulaires en cartes blanches.
struct SettingsView: View {
    enum Tab: Hashable { case general, groups, ai, advanced }
    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPills(selection: $tab,
                           options: [(Tab.general, L("Général")), (Tab.groups, L("Groupes")), (Tab.ai, L("IA")), (Tab.advanced, L("Avancé"))],
                           capsule: true, fontSize: 12.5, horizontalPadding: 14, verticalPadding: 4)
                .padding(.top, 2).padding(.bottom, 10)
            Group {
                switch tab {
                case .general: ScrollView { GeneralSettings().padding(pagePadding) }
                case .groups: GroupSettings().padding(pagePadding)
                case .ai: ScrollView { AISettings().padding(pagePadding) }
                case .advanced: ScrollView { AdvancedSettings().padding(pagePadding) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 640, height: 640)
        .dsSheet()
        .background(WindowAccessor { window in
            // Le contenu reste sous la barre de titre, rendue transparente sur le fond chaud.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(DS.window)
        })
    }

    private var pagePadding: EdgeInsets { EdgeInsets(top: 10, leading: 24, bottom: 24, trailing: 24) }
}

/// Section de réglages : intertitre et carte.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CapsLabel(title).frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(L("Synchronisation")) {
                CardRows {
                    FormRow(L("Fréquence par défaut"), subtitle: L("Un groupe peut avoir sa propre fréquence (clic droit dans la barre latérale).")) {
                        Picker(L("Fréquence par défaut"), selection: $model.settings.syncIntervalHours) {
                            ForEach(AppModel.intervalChoices, id: \.hours) { Text($0.label).tag($0.hours) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    toggleRow(L("Ouvrir WhatsApp avant chaque synchro"), $model.settings.openWhatsAppBeforeSync)
                    toggleRow(L("Lancer DistiX à l'ouverture de session"), $model.settings.launchAtLogin)
                    toggleRow(L("Une notification après chaque synchro"), $model.settings.notificationsEnabled)
                    HStack(spacing: 10) {
                        Button(L("Synchroniser maintenant")) { model.syncNow() }.buttonStyle(.pillCompact).disabled(model.isSyncing)
                        VStack(alignment: .leading, spacing: 2) {
                            if let p = model.syncProgress {
                                Text(p).lineLimit(1).truncationMode(.middle)
                            } else if let last = model.lastRun {
                                Text(model.lastSyncText(last))
                                if let e = last.error { Text(e).foregroundStyle(DS.red).lineLimit(3).textSelection(.enabled) }
                            } else {
                                Text(L("Aucune synchronisation pour l'instant."))
                            }
                        }
                        .font(.system(size: 12)).foregroundStyle(DS.text4)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            SettingsSection(L("Dernier traitement")) {
                if let run = model.lastMeaningfulRun {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            statCell(L("Messages lus"), Self.count(run.messagesRead), run.startedAt.formatted(date: .abbreviated, time: .shortened), first: true)
                            statCell(L("Fiches"), "\(run.fichesCreated) + \(run.fichesUpdated)",
                                     run.merges > 0 ? L("créées, mises à jour · \(run.merges) fusions") : L("créées, mises à jour"))
                            statCell(L("Jetons"), Self.compact(run.inputTokens + run.outputTokens),
                                     L("\(Self.compact(run.inputTokens)) entrée, \(Self.compact(run.outputTokens)) sortie"))
                            statCell(L("Coût estimé"), String(format: "%.3f $", run.costUSD).replacingOccurrences(of: ".", with: ","),
                                     model.settings.provider == .claudeCode ? L("inclus dans l'abonnement") : L("au tarif de l'API"))
                        }
                        .dsCard()
                        if let e = run.error {
                            Text(e).font(.system(size: 11.5)).foregroundStyle(DS.red).textSelection(.enabled).padding(.horizontal, 4)
                        }
                    }
                } else {
                    Text(L("Aucun traitement pour l'instant.")).font(.system(size: 13)).foregroundStyle(DS.text4)
                        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).dsCard()
                }
            }
            SettingsSection(L("Fiches et confidentialité")) {
                CardRows {
                    FormRow(L("Langue des fiches"), subtitle: L("Chaque groupe peut avoir sa propre langue (Objectif du groupe). S'applique aux prochaines fiches.")) {
                        Picker(L("Langue des fiches"), selection: $model.settings.ficheLanguage) {
                            Text(L("Langue d'origine")).tag(FicheLanguage.original)
                            ForEach(FicheLanguage.choices, id: \.code) { Text($0.name.capitalized).tag($0.code) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    toggleRow(L("Remplacer les noms par des alias avant l'envoi à l'IA"), $model.settings.pseudonymize)
                    toggleRow(L("Afficher les vrais noms dans DistiX"), $model.settings.showRealNames)
                }
            }
            SettingsSection(L("Mises à jour")) {
                let updater = Updater.shared
                CardRows {
                    if updater.isAvailable {
                        toggleRow(L("Rechercher automatiquement"),
                                  Binding(get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
                        HStack(spacing: 10) {
                            Text(updater.lastCheck.map { L("Version \(updater.version) · vérifiée \(DS.listDate($0, time: true).lowercased())") }
                                 ?? L("Version \(updater.version)"))
                                .font(.system(size: 12)).foregroundStyle(DS.text4).frame(maxWidth: .infinity, alignment: .leading)
                            Button(L("Rechercher maintenant")) { updater.checkNow() }.buttonStyle(.pillCompact)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    } else {
                        FormRow(L("Version \(updater.version)"),
                                subtitle: L("Version de développement : les mises à jour automatiques sont désactivées.")) { EmptyView() }
                    }
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        FormRow(title) {
            Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(DS.accent)
        }
    }

    private func statCell(_ label: String, _ value: String, _ note: String, first: Bool = false) -> some View {
        HStack(spacing: 0) {
            if !first { Rectangle().fill(DS.hairline).frame(width: 0.5) }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(DS.text4)
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.7)
                Text(note).font(.system(size: 11)).foregroundStyle(DS.text4).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "fr_FR")))
    }

    /// « 48 k » au-delà de dix mille.
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded())) k" }
        return count(n)
    }
}

struct GroupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var depth: HistoryDepth = .three

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Les groupes cochés sont synchronisés. L'historique choisi s'applique aux groupes que vous cochez maintenant."))
                .font(.system(size: 13)).lineSpacing(2).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            GroupPicker(depth: $depth, confirmUnselect: true, showGoal: true)
            HStack {
                Button(L("Actualiser la liste")) { Task { _ = await model.refreshGroups() } }.buttonStyle(.pillCompact)
                Spacer()
            }
        }
        .task { _ = await model.refreshGroups() }
        .sheet(item: Binding(get: { model.editingGoal }, set: { model.editingGoal = $0 })) { c in
            GroupGoalSheet(conversation: c).environment(model)
        }
    }
}

struct AISettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(L("Fournisseur")) { AIProviderForm(chooser: .menu) }
            LocalModelsSection()
        }
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(L("Reconstitution des fils")) {
                CardRows {
                    stepperRow(L("Messages par fenêtre"), "\(model.settings.windowSize)", $model.settings.windowSize, 20...200, 10)
                    stepperRow(L("Recouvrement"), "\(model.settings.windowOverlap)", $model.settings.windowOverlap, 0...50, 5)
                    stepperRow(L("Un fil reste ouvert"), L("\(model.settings.threadOpenDays) jours"), $model.settings.threadOpenDays, 1...60, 1)
                }
            }
            SettingsSection(L("Fusion des questions similaires")) {
                CardRows {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Seuil de similarité")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.2f", model.settings.mergeThreshold).replacingOccurrences(of: ".", with: ","))
                                .monospacedDigit().foregroundStyle(DS.text2)
                        }
                        .font(.system(size: 13))
                        Slider(value: $model.settings.mergeThreshold, in: 0.5...0.98).controlSize(.small).tint(DS.accent)
                            .accessibilityLabel(L("Seuil de similarité"))
                        HStack {
                            Text(L("Fusionne plus")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("Fusionne moins"))
                        }
                        .font(.system(size: 11)).foregroundStyle(DS.text4)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    FormRow(L("Fusionner aussi entre groupes différents")) {
                        Toggle(L("Fusionner aussi entre groupes différents"), isOn: $model.settings.crossGroupMerge)
                            .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(DS.accent)
                    }
                }
            }
            Button { model.showOnboarding = true } label: {
                HStack {
                    Text(L("Revoir l'accueil")).font(.system(size: 13)).foregroundStyle(DS.text).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text4)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .dsCard()
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .handCursor()
        }
    }

    private func stepperRow(_ title: String, _ value: String, _ binding: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        FormRow(title) {
            Text(value).font(.system(size: 13)).monospacedDigit().foregroundStyle(DS.text2)
            Stepper(title, value: binding, in: range, step: step).labelsHidden().controlSize(.small)
        }
    }
}
