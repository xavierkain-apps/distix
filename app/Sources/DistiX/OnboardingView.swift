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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= step ? DS.accent : DS.fillStrong).frame(height: 4)
                }
            }
            .accessibilityElement().accessibilityLabel(L("Étape \(step + 1) sur 3"))
            HStack(spacing: 8) {
                AppIconView(size: 20)
                Text(L("Étape \(step + 1) sur 3")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.accent)
            }
            .padding(.top, 26)
            Group {
                switch step {
                case 0: AccessStep(next: { step = 1 })
                case 1: GroupsStep(back: { step = 0 }, next: { step = 2 })
                default: AIStep(back: { step = 1 }, finish: { model.startAfterOnboarding() })
                }
            }
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 22, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 640, height: 600)
        .dsSheet()
    }
}

/// Titre d'une étape de l'accueil.
private struct StepTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 26, weight: .bold)).tracking(-0.5).foregroundStyle(DS.text)
    }
}

struct AccessStep: View {
    @Environment(AppModel.self) private var model
    let next: () -> Void
    @State private var status: SourceStatus?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepTitle(L("Accès à WhatsApp"))
            Text(L("DistiX lit, en lecture seule, les messages que WhatsApp Desktop enregistre sur ce Mac. Il n'écrit jamais rien dans WhatsApp et n'utilise aucun appareil lié."))
                .font(.system(size: 14)).lineSpacing(3.5).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            Text(L("WhatsApp Desktop doit être installé et connecté à votre compte. Les messages ne sont disponibles que lorsque WhatsApp est ouvert de temps en temps."))
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
            statusCard.padding(.top, 8)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L("Continuer")) { next() }.buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction).disabled(status != .available)
            }
        }
        .task { check() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if checking {
                statusHead(symbol: "…", tint: DS.accent, title: L("Vérification…"))
                Text(L("Si macOS demande d'autoriser DistiX à accéder aux données d'autres apps, cliquez sur « Autoriser » : la vérification attend votre réponse."))
                    .font(.system(size: 13.5)).lineSpacing(2.5).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            } else {
                switch status {
                case .available?:
                    statusHead(symbol: "✓", tint: DS.green, title: L("La base WhatsApp est lisible."))
                case .notInstalled?:
                    statusHead(symbol: "!", tint: DS.red, title: L("WhatsApp Desktop est introuvable"))
                    Text(L("Installez-le depuis whatsapp.com ou l'App Store, connectez-vous, puis réessayez."))
                        .font(.system(size: 13.5)).foregroundStyle(DS.text2)
                case .permissionDenied?:
                    statusHead(symbol: "!", tint: DS.orange, title: L("macOS demande votre autorisation"))
                    VStack(alignment: .leading, spacing: 10) {
                        numbered(1, L("Ouvrez Réglages Système, Confidentialité et sécurité, Accès complet au disque."))
                        numbered(2, L("Activez DistiX (ajoutez-le avec + s'il n'apparaît pas)."))
                        numbered(3, L("Revenez ici et cliquez sur « Vérifier l'accès »."))
                    }
                case .schemaChanged(let missing)?:
                    statusHead(symbol: "!", tint: DS.red, title: L("Le format de la base WhatsApp a changé"))
                    Text(L("DistiX doit être mis à jour (\(missing.joined(separator: ", "))).")).font(.system(size: 13.5)).foregroundStyle(DS.text2)
                case .unreadable(let e)?:
                    statusHead(symbol: "!", tint: DS.red, title: L("La base WhatsApp est illisible"))
                    Text(e).font(.system(size: 13.5)).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                case nil:
                    statusHead(symbol: "…", tint: DS.accent, title: L("Vérification…"))
                }
            }
            HStack(spacing: 8) {
                if case .permissionDenied? = status, !checking {
                    Button(L("Ouvrir les Réglages")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(.pillCompact)
                }
                Button(checking ? L("Vérification…") : L("Vérifier l'accès")) { check() }
                    .buttonStyle(.pillCompact).disabled(checking)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func statusHead(symbol: String, tint: Color, title: String) -> some View {
        HStack(spacing: 10) {
            Text(symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                .frame(width: 22, height: 22).background(tint.opacity(0.16), in: Circle())
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").fontWeight(.semibold).foregroundStyle(DS.text4).frame(width: 22, alignment: .leading)
            Text(text).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13.5)).lineSpacing(2)
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

/// Liste de groupes à cocher, partagée par l'accueil, la feuille des groupes et les réglages.
struct GroupPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var depth: HistoryDepth
    var confirmUnselect = false
    var showGoal = false
    @State private var filter = ""
    @State private var pendingUnselect: ConversationRecord?

    private var shown: [ConversationRecord] {
        model.conversations.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                RoundSearchField(prompt: L("Filtrer les groupes"), text: $filter, height: 26)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                Rectangle().fill(DS.hairline).frame(height: 0.5)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, c in
                            if index > 0 { Rectangle().fill(DS.hairline).frame(height: 0.5) }
                            row(c)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .dsCard()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                Text(L("Historique à traiter")).font(.system(size: 13)).foregroundStyle(DS.text2)
                SegmentedPills(selection: $depth, options: HistoryDepth.allCases.map { ($0, $0.label) })
            }
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

    private func row(_ c: ConversationRecord) -> some View {
        let usable = c.messageCount > 0
        return HStack(spacing: 12) {
            // La case et le nom forment un seul contrôle ; le bouton d'objectif reste distinct.
            Button {
                if c.selected && confirmUnselect { pendingUnselect = c }
                else { model.setSelected(c, selected: !c.selected, historyStart: depth.start) }
            } label: {
                HStack(spacing: 12) {
                    CheckMark(isOn: c.selected)
                    Text(c.name).font(.system(size: 13)).foregroundStyle(usable ? DS.text : DS.text4)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .accessibilityLabel(c.name)
            .accessibilityValue(c.selected ? L("coché") : L("décoché"))
            .accessibilityAddTraits(c.selected ? .isSelected : [])
            Text(usable ? L("\(c.messageCount) messages") : L("aucun message exploitable"))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text4).lineLimit(1)
            Text(c.lastMessageAt.map { DS.listDate($0) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(DS.text4).lineLimit(1).frame(width: 76, alignment: .trailing)
            if showGoal {
                if c.selected {
                    Button(c.mode == .watch ? L("Veille") : L("Objectif")) { model.editingGoal = c }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.accent)
                        .frame(width: 56, alignment: .trailing)
                        .handCursor()
                        .help(L("Objectif du groupe"))
                        .accessibilityLabel(L("Objectif du groupe \(c.name)"))
                } else {
                    Color.clear.frame(width: 56, height: 1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Case à cocher aux couleurs de DistiX.
struct CheckMark: View {
    let isOn: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? DS.accent : DS.card)
            .overlay { if !isOn { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.text4.opacity(0.55), lineWidth: 1) } }
            .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white) } }
            .frame(width: 16, height: 16)
    }
}

struct GroupsStep: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    let next: () -> Void
    @State private var depth: HistoryDepth = .three

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                StepTitle(L("Choix des groupes"))
                Text(L("Seuls les groupes cochés sont lus. Ces conversations contiennent les messages d'autres personnes : l'usage de DistiX doit rester personnel."))
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
            }
            GroupPicker(depth: $depth)
            estimate
            HStack(spacing: 10) {
                Button(L("Retour")) { back() }.buttonStyle(.pill)
                Spacer()
                Button(L("Continuer")) {
                    for c in model.selectedConversations { model.setSelected(c, selected: true, historyStart: depth.start) }
                    next()
                }
                .buttonStyle(.pillPrimary)
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
            .font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
    }
}

struct AIStep: View {
    @Environment(AppModel.self) private var model
    let back: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(L("Intelligence artificielle"))
            Text(L("Ce qui quitte le Mac : uniquement le texte des messages des groupes cochés, avec les noms remplacés par des alias et les numéros masqués, envoyé au fournisseur d'IA choisi ci-dessous. Rien d'autre."))
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(DS.accentInk).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            AIProviderForm(chooser: .cards)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(L("Retour")) { back() }.buttonStyle(.pill)
                Spacer()
                Button(L("Terminer et lancer le premier traitement")) { finish() }.buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Champ de texte aligné à droite dans une ligne de formulaire.
struct RowTextField: View {
    let prompt: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure { SecureField("", text: $text, prompt: Text(prompt)) }
            else { TextField("", text: $text, prompt: Text(prompt)) }
        }
        .textFieldStyle(.plain).font(.system(size: 13)).multilineTextAlignment(.trailing)
        .foregroundStyle(DS.text2)
        .frame(maxWidth: 300)
    }
}

/// Choix du fournisseur, clé et test de connexion (accueil et réglages).
struct AIProviderForm: View {
    enum Chooser { case cards, menu }
    @Environment(AppModel.self) private var model
    var chooser: Chooser = .menu
    @State private var apiKey = ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: chooser == .cards ? 14 : 0) {
            if chooser == .cards {
                HStack(spacing: 8) {
                    providerCard(.claudeCode, L("Mon abonnement Claude"), L("Via Claude Code, aucune clé"))
                    providerCard(.anthropic, L("API Anthropic"), L("Clé dans le Trousseau"))
                    providerCard(.openAICompatible, L("Modèle local"), L("Ollama, LM Studio, compatible OpenAI"))
                }
            }
            CardRows {
                if chooser == .menu {
                    FormRow(L("Fournisseur")) {
                        Picker(L("Fournisseur"), selection: $model.settings.provider) {
                            Text(L("Mon abonnement Claude (via Claude Code)")).tag(ProviderKind.claudeCode)
                            Text(L("API Anthropic (clé)")).tag(ProviderKind.anthropic)
                            Text(L("Modèle local ou compatible OpenAI")).tag(ProviderKind.openAICompatible)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                switch model.settings.provider {
                case .claudeCode:
                    FormRow(L("Chemin de claude"), subtitle: chooser == .menu ? L("Utilise Claude Code installé sur ce Mac et votre abonnement Claude. Aucune clé à saisir.") : nil) {
                        RowTextField(prompt: model.claudeLocated ?? L("introuvable"), text: $model.settings.claudePath)
                    }
                case .anthropic:
                    FormRow(L("Clé API"), subtitle: L("La clé est conservée dans le Trousseau macOS.")) {
                        RowTextField(prompt: "sk-ant-…", text: $apiKey, secure: true)
                    }
                case .openAICompatible:
                    FormRow(L("Adresse du serveur")) {
                        RowTextField(prompt: "http://localhost:11434/v1", text: $model.settings.openAIBaseURL)
                    }
                    FormRow(L("Clé (si nécessaire)")) {
                        RowTextField(prompt: L("aucune"), text: $apiKey, secure: true)
                    }
                }
                FormRow(L("Modèle pour les fils")) {
                    RowTextField(prompt: AppSettings.defaultModels(model.settings.provider).attribution, text: $model.settings.attributionModel)
                }
                FormRow(L("Modèle pour les fiches")) {
                    RowTextField(prompt: AppSettings.defaultModels(model.settings.provider).fiche, text: $model.settings.ficheModel)
                }
                HStack(spacing: 10) {
                    Button(testing ? L("Test en cours…") : L("Tester la connexion")) { test() }
                        .buttonStyle(.pillCompact).disabled(testing)
                    if let testResult {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            StatusDot(color: testResult.ok ? DS.greenDot : DS.red, size: 7)
                            Text(testResult.text).foregroundStyle(testResult.ok ? DS.green : DS.red)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12.5))
                    } else if model.settings.provider == .openAICompatible {
                        Text(L("Ollama : localhost:11434 · LM Studio : localhost:1234")).font(.system(size: 12)).foregroundStyle(DS.text4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .onAppear { loadKey() }
        .onChange(of: apiKey) { if model.settings.provider != .claudeCode { Keychain.set(apiKey, for: account) } }
        .onChange(of: model.settings.provider) { loadKey(); testResult = nil }
        .onChange(of: model.settings.claudePath) { model.refreshClaudeLocation() }
    }

    private func providerCard(_ kind: ProviderKind, _ title: String, _ text: String) -> some View {
        let isOn = model.settings.provider == kind
        return Button { model.settings.provider = kind } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Text(text).font(.system(size: 11.5)).lineSpacing(1.5).foregroundStyle(DS.text4)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(DS.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? DS.accent : DS.outline, lineWidth: isOn ? 2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
                testResult = (true, L("Connexion réussie"))
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}
