import DistiXCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("Général"), systemImage: "gearshape") }
            GroupSettings().tabItem { Label(L("Groupes"), systemImage: "person.3") }
            AIProviderForm().padding().tabItem { Label(L("IA"), systemImage: "sparkles") }
            AdvancedSettings().tabItem { Label(L("Avancé"), systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L("Synchronisation")) {
                Picker(L("Fréquence par défaut"), selection: $model.settings.syncIntervalHours) {
                    ForEach(AppModel.intervalChoices, id: \.hours) { Text($0.label).tag($0.hours) }
                }
                Text(L("Un groupe peut avoir sa propre fréquence : clic droit sur le groupe dans la barre latérale."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Ouvrir WhatsApp avant chaque synchro"), isOn: $model.settings.openWhatsAppBeforeSync)
                Toggle(L("Lancer DistiX à l'ouverture de session"), isOn: $model.settings.launchAtLogin)
                Toggle(L("Notification après une synchro (une seule par synchro)"), isOn: $model.settings.notificationsEnabled)
                HStack {
                    Button(L("Synchroniser maintenant")) { model.syncNow() }.disabled(model.isSyncing)
                    if let p = model.syncProgress { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Section(L("Dernier traitement")) {
                if let run = model.lastRun {
                    LabeledContent(L("Date"), value: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent(L("Messages lus"), value: "\(run.messagesRead)")
                    LabeledContent(L("Fiches"), value: L("\(run.fichesCreated) créées, \(run.fichesUpdated) mises à jour, \(run.merges) fusions"))
                    LabeledContent(L("Jetons"), value: L("\(run.inputTokens) en entrée, \(run.outputTokens) en sortie"))
                    LabeledContent(L("Coût estimé"), value: String(format: "%.3f $", run.costUSD))
                    if model.settings.provider == .claudeCode {
                        Text(L("Avec l'abonnement Claude, ce montant est l'équivalent au tarif de l'API : il n'est pas facturé en plus."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let e = run.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                } else {
                    Text(L("Aucune synchronisation pour l'instant."))
                }
            }
            Section(L("Confidentialité")) {
                Toggle(L("Remplacer les noms par des alias avant l'envoi à l'IA"), isOn: $model.settings.pseudonymize)
                Toggle(L("Afficher les vrais noms dans DistiX"), isOn: $model.settings.showRealNames)
            }
        }
        .formStyle(.grouped)
    }
}

struct GroupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var depth: HistoryDepth = .three

    var body: some View {
        VStack(alignment: .leading) {
            Text(L("Les groupes cochés sont synchronisés. La profondeur d'historique s'applique aux groupes que vous cochez maintenant."))
                .font(.callout).foregroundStyle(.secondary)
            GroupPicker(depth: $depth, confirmUnselect: true)
            Button(L("Actualiser la liste")) { Task { _ = await model.refreshGroups() } }
        }
        .padding()
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L("Reconstitution des fils")) {
                Stepper(L("Messages par fenêtre : \(model.settings.windowSize)"), value: $model.settings.windowSize, in: 20...200, step: 10)
                Stepper(L("Recouvrement : \(model.settings.windowOverlap)"), value: $model.settings.windowOverlap, in: 0...50, step: 5)
                Stepper(L("Un fil reste ouvert \(model.settings.threadOpenDays) jours"), value: $model.settings.threadOpenDays, in: 1...60)
            }
            Section(L("Fusion des questions similaires")) {
                Slider(value: $model.settings.mergeThreshold, in: 0.5...0.98) {
                    Text(L("Seuil de similarité : \(String(format: "%.2f", model.settings.mergeThreshold))"))
                }
                Toggle(L("Fusionner aussi entre groupes différents"), isOn: $model.settings.crossGroupMerge)
            }
            Section {
                Button(L("Revoir l'accueil")) { model.showOnboarding = true }
            }
        }
        .formStyle(.grouped)
    }
}
