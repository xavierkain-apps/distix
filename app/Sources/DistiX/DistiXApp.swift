import DistiXCore
import SwiftUI

@main
struct DistiXApp: App {
    @State private var model: AppModel

    init() {
        // Utilisé par scripts/build-app.sh : si on arrive ici, dyld a chargé Sparkle. On sort
        // avant de créer le modèle, qui ouvrirait la base et lancerait une synchro.
        if CommandLine.arguments.contains("--distix-dyld-check") { exit(0) }
        _model = State(initialValue: AppModel())
    }
    private let updater = Updater.shared

    var body: some Scene {
        Window("DistiX", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button(L("Rechercher des mises à jour…")) { updater.checkNow() }
                }
            }
            CommandGroup(replacing: .help) {
                Button(L("Découvrir DistiX")) { model.showTour = true }
            }
            CommandGroup(after: .newItem) {
                Button(L("Synchroniser maintenant")) { model.syncNow() }
                    .keyboardShortcut("r")
                    .disabled(model.isSyncing)
                Divider()
                Button(L("Exporter les fiches validées…")) { model.exportFolder(conversationId: nil, onlyValidated: true) }
                Button(L("Exporter toute la base…")) { model.exportFolder(conversationId: nil) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            FicheCommands(model: model)
            GroupCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: AppIconArt.menuBarImage)
                if model.totalUnread > 0 { Text("\(model.totalUnread)") }
            }
            .accessibilityLabel(L("DistiX, \(model.totalUnread) fiches non lues"))
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.totalUnread == 1 ? L("1 fiche non lue") : L("\(model.totalUnread) fiches non lues"))
        if let progress = model.syncProgress {
            Text(progress)
        } else if let run = model.lastRun {
            Text(model.lastSyncText(run))
            if let e = run.error { Text(L("Erreur : \(e)")) }
        }
        Divider()
        Button(L("Synchroniser maintenant")) { model.syncNow() }.keyboardShortcut("r").disabled(model.isSyncing)
        Button(L("Ouvrir DistiX")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text(L("Réglages…")) }.keyboardShortcut(",")
        Divider()
        Button(L("Quitter DistiX")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Menu « Fiche » : les actions sur la fiche sélectionnée, avec raccourcis.
struct FicheCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu(L("Fiche")) {
            let fiche = model.selectedFiche
            Button(fiche?.review == .validated ? L("Ne plus valider") : L("Valider")) { if let fiche { model.review(fiche, .validated) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(fiche == nil)
            Button(fiche?.review == .discarded ? L("Ne plus écarter") : L("Écarter")) { if let fiche { model.review(fiche, .discarded) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(fiche == nil)
            Button(L("Marquer comme non lue")) { if let id = model.selectedFicheId { model.markUnread(itemId: id) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.selectedFicheId == nil)
            Divider()
            Button(L("Copier en Markdown")) { if let fiche { model.copyMarkdown(fiche) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(fiche == nil)
            Button(L("Exporter en .md…")) { if let fiche { model.exportFiche(fiche) } }
                .disabled(fiche == nil)
            Menu(L("Régénérer avec")) {
                ForEach(model.modelChoices) { choice in
                    Button(choice.label) { if let fiche { model.regenerate(fiche, with: choice) } }
                }
                if !model.unavailableModelNotes.isEmpty { Divider() }
                ForEach(model.unavailableModelNotes, id: \.self) { Text($0) }
            }
            .disabled(fiche == nil)
            Menu(L("Traduire en")) {
                ForEach(FicheLanguage.choices, id: \.code) { lang in
                    Button(lang.name.capitalized) { if let fiche { model.translate(fiche, to: lang.code) } }
                }
            }
            .disabled(fiche == nil)
            Divider()
            Picker(L("Afficher"), selection: Binding(get: { model.reviewFilter }, set: { model.reviewFilter = $0 })) {
                Text(L("Toutes (sauf écartées)")).tag(Store.ReviewFilter.kept)
                Text(L("À trier")).tag(Store.ReviewFilter.toReview)
                Text(L("Validées")).tag(Store.ReviewFilter.validated)
                Text(L("Écartées")).tag(Store.ReviewFilter.discarded)
            }
            Button(L("Tout marquer comme lu")) { model.markAllRead() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}

/// Menu « Groupe » : gestion des groupes et du groupe courant.
struct GroupCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu(L("Groupe")) {
            let c = model.currentConversation
            Button(L("Ajouter ou retirer des groupes…")) { model.showGroups = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button(L("Objectif du groupe…")) { model.editingGoal = c }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(c == nil)
            Button(L("Nouveau thème…")) { if let c { model.newTheme(in: c.id) } }
                .disabled(c == nil || c?.mode == .watch)
            Button(L("Exporter ce groupe…")) { if let c { model.exportFolder(conversationId: c.id) } }
                .disabled(c == nil)
            Divider()
            Button(L("Retraiter ce groupe…")) { model.confirmReprocess = c }
                .disabled(c == nil)
        }
    }
}
