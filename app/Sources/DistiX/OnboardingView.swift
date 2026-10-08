import DistiXCore
import SwiftUI

/// Configuration en trois écrans (brief § 7.1), sans toucher au code.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var toured = false

    var body: some View {
        if !toured {
            FeatureTour(onFinish: { toured = true })
        } else {
            steps
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(height: 4)
                }
            }
            .padding()
            Group {
                switch step {
                case 0: AccessStep(next: { step = 1 })
                case 1: GroupsStep(back: { step = 0 }, next: { step = 2 })
                default: AIStep(back: { step = 1 }, finish: { model.startAfterOnboarding() })
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(width: 640, height: 600)
    }
}

struct AccessStep: View {
    @Environment(AppModel.self) private var model
    let next: () -> Void
    @State private var status: SourceStatus?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Accès à WhatsApp")).font(.title.bold())
            Text(L("DistiX lit, en lecture seule, les messages que WhatsApp Desktop enregistre sur ce Mac. Il n'écrit jamais rien dans WhatsApp et n'utilise aucun appareil lié."))
            Text(L("WhatsApp Desktop doit être installé et connecté à votre compte. Les messages ne sont disponibles que lorsque WhatsApp est ouvert de temps en temps."))
                .foregroundStyle(.secondary)
            Spacer().frame(height: 6)
            Button(checking ? L("Vérification…") : L("Vérifier l'accès")) { check() }.disabled(checking)
            if checking {
                Label(L("Si macOS demande d'autoriser DistiX à accéder aux données d'autres apps, cliquez sur « Autoriser » : la vérification attend votre réponse."),
                      systemImage: "hand.raised").font(.callout).foregroundStyle(.orange)
            }
            switch status {
            case .available?:
                Label(L("La base WhatsApp est lisible."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notInstalled?:
                Label(L("WhatsApp Desktop est introuvable. Installez-le depuis whatsapp.com ou l'App Store, connectez-vous, puis réessayez."),
                      systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .permissionDenied?:
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("macOS demande votre autorisation."), systemImage: "lock.fill").foregroundStyle(.orange)
                    Text(L("1. Ouvrez Réglages Système > Confidentialité et sécurité > Accès complet au disque.\n2. Activez DistiX (ajoutez-le avec + s'il n'apparaît pas).\n3. Revenez ici et cliquez sur « Vérifier l'accès »."))
                    Button(L("Ouvrir les Réglages")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            case .schemaChanged(let missing)?:
                Label(L("Le format de la base WhatsApp a changé (\(missing.joined(separator: ", "))). DistiX doit être mis à jour."),
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .unreadable(let e)?:
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case nil:
                EmptyView()
            }
            Spacer()
            HStack {
                Spacer()
                Button(L("Continuer")) { next() }.keyboardShortcut(.defaultAction).disabled(status != .available)
            }
        }
        .task { check() }
    }

    private func check() {
        checking = true
        Task {
            status = await model.refreshGroups()
            checking = false
        }
    }
}

enum HistoryDepth: Int, CaseIterable, Identifiable {
    case one = 1, three = 3, six = 6, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .one: return L("1 mois")
        case .three: return L("3 mois")
        case .six: return L("6 mois")
        case .all: return L("Tout")
        }
    }
    var start: Date? {
        rawValue == 0 ? nil : Calendar.current.date(byAdding: .month, value: -rawValue, to: Date())
    }
}

/// Liste de groupes à cocher, partagée par l'accueil et les réglages.
struct GroupPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var depth: HistoryDepth
    var confirmUnselect = false
    var showGoal = false
    @State private var filter = ""
    @State private var pendingUnselect: ConversationRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Filtrer les groupes"), text: $filter).textFieldStyle(.roundedBorder)
            List {
                ForEach(model.conversations.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { c in
                    Toggle(isOn: Binding(get: { c.selected }, set: { on in
                        if !on && confirmUnselect { pendingUnselect = c } else { model.setSelected(c, selected: on, historyStart: depth.start) }
                    })) {
                        HStack {
                            Text(c.name)
                            Spacer()
                            Text(c.messageCount == 0 ? L("aucun message exploitable") : L("\(c.messageCount) messages"))
                                .foregroundStyle(.secondary)
                            Text(c.lastMessageAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                                .foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            if c.selected && showGoal {
                                Button { model.editingGoal = c } label: {
                                    Image(systemName: c.mode == .watch ? "binoculars" : "target")
                                }
                                .buttonStyle(.borderless)
                                .help(L("Objectif du groupe"))
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            Picker(L("Historique à traiter"), selection: $depth) {
                ForEach(HistoryDepth.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .confirmationDialog(L("Décocher ce groupe ?"), isPresented: Binding(get: { pendingUnselect != nil }, set: { if !$0 { pendingUnselect = nil } })) {
            Button(L("Décocher et supprimer ses fiches"), role: .destructive) {
                if let c = pendingUnselect { model.setSelected(c, selected: false, historyStart: nil); model.deleteData(of: c.id) }
            }
            Button(L("Décocher en gardant les fiches")) {
                if let c = pendingUnselect { model.setSelected(c, selected: false, historyStart: nil) }
            }
        } message: {
            Text(L("Ses messages, fils et fiches peuvent être supprimés de ce Mac."))
        }
    }
}

struct GroupsStep: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    let next: () -> Void
    @State private var depth: HistoryDepth = .three

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Choix des groupes")).font(.title.bold())
            Text(L("Seuls les groupes cochés sont lus. Ces conversations contiennent les messages d'autres personnes : l'usage de DistiX doit rester personnel."))
                .foregroundStyle(.secondary)
            GroupPicker(depth: $depth)
            estimate
            HStack {
                Button(L("Retour")) { back() }
                Spacer()
                Button(L("Continuer")) {
                    for c in model.selectedConversations { model.setSelected(c, selected: true, historyStart: depth.start) }
                    next()
                }
                .keyboardShortcut(.defaultAction).disabled(model.selectedConversations.isEmpty)
            }
        }
    }

    /// Volume approximatif sur la période choisie, en supposant une activité régulière.
    private var estimate: some View {
        let messages = model.selectedConversations.reduce(0) { sum, c in
            guard let start = depth.start, let last = c.lastMessageAt else { return sum + c.messageCount }
            let span = max(1, last.timeIntervalSince(Calendar.current.date(byAdding: .year, value: -2, to: last)!))
            let share = min(1, max(0, last.timeIntervalSince(start)) / span)
            return sum + Int(Double(c.messageCount) * max(share, 0.05))
        }
        let e = CostEstimator.estimate(messages: messages, settings: model.settings)
        return Text(L("Premier traitement estimé : environ \(messages) messages, \(e.minutes) min, \(String(format: "%.2f", e.usd)) $ au tarif de l'API (inclus si vous utilisez votre abonnement Claude)."))
            .font(.callout).foregroundStyle(.secondary)
    }
}

struct AIStep: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Intelligence artificielle")).font(.title.bold())
            Text(L("Ce qui quitte le Mac : uniquement le texte des messages des groupes cochés, avec les noms remplacés par des alias et les numéros masqués, envoyé au fournisseur d'IA choisi ci-dessous. Rien d'autre."))
                .padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            AIProviderForm()
            Spacer()
            HStack {
                Button(L("Retour")) { back() }
                Spacer()
                Button(L("Terminer et lancer le premier traitement")) { finish() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Choix du fournisseur, clé et test de connexion (accueil et réglages).
struct AIProviderForm: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Picker(L("Fournisseur"), selection: $model.settings.provider) {
                Text(L("Mon abonnement Claude (via Claude Code)")).tag(ProviderKind.claudeCode)
                Text(L("API Anthropic (clé)")).tag(ProviderKind.anthropic)
                Text(L("Modèle local ou compatible OpenAI")).tag(ProviderKind.openAICompatible)
            }
            switch model.settings.provider {
            case .claudeCode:
                Text(L("Utilise Claude Code installé sur ce Mac et votre abonnement Claude. Aucune clé à saisir."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(L("Chemin de claude (facultatif)"), text: $model.settings.claudePath,
                          prompt: Text(ClaudeCodeProvider.candidates().first?.path ?? L("introuvable")))
            case .anthropic:
                SecureField(L("Clé API"), text: $apiKey, prompt: Text("sk-ant-…"))
                Text(L("La clé est conservée dans le Trousseau macOS.")).font(.callout).foregroundStyle(.secondary)
            case .openAICompatible:
                TextField(L("Adresse du serveur"), text: $model.settings.openAIBaseURL)
                SecureField(L("Clé (si nécessaire)"), text: $apiKey)
                Text(L("Ollama : http://localhost:11434/v1 — LM Studio : http://localhost:1234/v1")).font(.callout).foregroundStyle(.secondary)
            }
            TextField(L("Modèle pour les fils"), text: $model.settings.attributionModel,
                      prompt: Text(AppSettings.defaultModels(model.settings.provider).attribution))
            TextField(L("Modèle pour les fiches"), text: $model.settings.ficheModel,
                      prompt: Text(AppSettings.defaultModels(model.settings.provider).fiche))
            HStack {
                Button(testing ? L("Test en cours…") : L("Tester la connexion")) { test() }.disabled(testing)
                if let testResult { Text(testResult).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadKey() }
        .onChange(of: apiKey) { if model.settings.provider != .claudeCode { Keychain.set(apiKey, for: account) } }
        .onChange(of: model.settings.provider) { loadKey(); testResult = nil }
    }

    private var account: String {
        model.settings.provider == .anthropic ? ProviderFactory.anthropicKeyAccount : ProviderFactory.openAIKeyAccount
    }

    private func loadKey() { apiKey = Keychain.get(account) ?? "" }

    private func test() {
        if model.settings.provider != .claudeCode { Keychain.set(apiKey, for: account) }
        testing = true
        testResult = nil
        let settings = model.settings
        Task {
            do {
                let provider = try await Task.detached { try ProviderFactory.make(settings) }.value
                struct R: Decodable { let ok: Bool }
                _ = try await provider.generate(LLMRequest(system: "Réponds en JSON.", user: "Renvoie ok = true.",
                                                           schema: Schema.object(["ok": Schema.boolean]),
                                                           model: settings.effectiveAttributionModel(), maxTokens: 200),
                                                as: R.self, attempts: 1)
                testResult = "✅ " + L("Connexion réussie")
            } catch {
                testResult = "❌ " + error.localizedDescription
            }
            testing = false
        }
    }
}
