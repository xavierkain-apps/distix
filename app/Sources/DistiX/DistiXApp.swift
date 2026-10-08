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
                .frame(minWidth: 960, minHeight: 600)
        }
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
                Button(L("Exporter toute la base…")) { model.exportFolder(conversationId: nil) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            if model.totalUnread > 0 {
                Label("\(model.totalUnread)", systemImage: "text.book.closed.fill").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "text.book.closed")
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let progress = model.syncProgress {
            Text(progress)
        } else if let run = model.lastRun {
            Text(L("Dernière synchro : \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"))
            if let e = run.error { Text(L("Erreur : \(e)")) }
        }
        Text(L("\(model.totalUnread) fiches non lues"))
        Divider()
        Button(L("Synchroniser maintenant")) { model.syncNow() }.disabled(model.isSyncing)
        Button(L("Ouvrir DistiX")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text(L("Réglages…")) }
        Divider()
        Button(L("Quitter DistiX")) { NSApp.terminate(nil) }
    }
}
