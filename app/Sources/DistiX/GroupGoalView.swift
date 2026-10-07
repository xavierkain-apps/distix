import DistiXCore
import SwiftUI

/// Suggestions de consignes, à compléter par l'utilisateur.
struct GoalTemplate: Identifiable {
    let id = UUID()
    let title: String
    let text: String

    static func list(for mode: GroupMode) -> [GoalTemplate] {
        switch mode {
        case .knowledge:
            return [
                GoalTemplate(title: L("Tout ce qui est utile"), text: ""),
                GoalTemplate(title: L("Entraide professionnelle"), text: L("Groupe d'entraide entre professionnels. Garde chaque question posée avec les réponses et les avis divergents, les retours d'expérience chiffrés et les ressources partagées (outils, contacts, liens).")),
                GoalTemplate(title: L("Équipe ou association"), text: L("Groupe d'organisation d'une équipe. Garde les décisions prises, les règles, les informations pratiques durables (lieux, matériel, horaires réguliers, contacts) et les retours d'expérience. Ignore la coordination du jour même.")),
                GoalTemplate(title: L("Sujets précis"), text: L("Garde surtout les échanges sur : [sujets qui m'intéressent]. Ignore : [sujets sans intérêt pour moi].")),
            ]
        case .watch:
            return [
                GoalTemplate(title: L("Je loue un logement"), text: L("Je propose à la location : [type, surface, ville ou quartier], [loyer] charges comprises, disponible à partir du [date], [meublé ou non]. Locataire idéal : [profil, durée, budget, garanties]. Repère les personnes qui cherchent un logement compatible.")),
                GoalTemplate(title: L("Je cherche un logement"), text: L("Je cherche à louer : [type, surface minimale], à [ville ou quartiers], budget maximum [montant], à partir du [date]. Repère les offres de logement compatibles.")),
                GoalTemplate(title: L("Petites annonces"), text: L("Je cherche : [objet, caractéristiques, état, budget]. Repère les annonces de vente, d'échange ou de don qui correspondent.")),
                GoalTemplate(title: L("Missions ou clients"), text: L("Je propose mes services de [métier] à [zone]. Repère les personnes qui cherchent ce type de prestation.")),
            ]
        }
    }
}

/// Ce que l'utilisateur attend d'un groupe : mode et consignes.
struct GroupGoalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: ConversationRecord
    @State private var mode: GroupMode = .knowledge
    @State private var focus = ""
    @State private var language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Objectif du groupe")).font(.title2.bold())
            Text(conversation.name).foregroundStyle(.secondary)
            Picker(L("Mode"), selection: $mode) {
                Text(L("Base de connaissances")).tag(GroupMode.knowledge)
                Text(L("Veille")).tag(GroupMode.watch)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(mode == .knowledge
                 ? L("Les échanges deviennent des fiches classées par thème. Précisez, si vous le souhaitez, ce qui vous intéresse dans ce groupe.")
                 : L("Seuls les messages qui correspondent à vos critères sont retenus, en opportunités notées sur 100. Décrivez précisément ce que vous cherchez ou proposez."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Suggestions")).font(.headline)
            HStack {
                ForEach(GoalTemplate.list(for: mode)) { t in
                    Button(t.title) { focus = t.text }.buttonStyle(.bordered)
                }
            }
            TextEditor(text: $focus)
                .font(.body)
                .frame(minHeight: 140)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if mode == .watch && focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(L("Sans critères, la veille ne retient rien."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text(L("Ces consignes sont envoyées à l'IA avec les messages du groupe. Remplacez les passages entre crochets."))
                .font(.caption).foregroundStyle(.secondary)
            if mode == .knowledge {
                Picker(L("Langue des fiches"), selection: $language) {
                    Text(L("Par défaut (\(model.settings.ficheLanguage.isEmpty ? L("langue d'origine") : FicheLanguage.name(model.settings.ficheLanguage)))"))
                        .tag(String?.none)
                    Text(L("Langue d'origine de la conversation")).tag(String?.some(FicheLanguage.original))
                    ForEach(FicheLanguage.choices, id: \.code) { Text($0.name.capitalized).tag(String?.some($0.code)) }
                }
                .frame(maxWidth: 420)
            }
            HStack {
                Spacer()
                Button(L("Annuler"), role: .cancel) { dismiss() }
                Button(L("Enregistrer")) {
                    model.saveGoal(conversation, mode: mode, focus: focus, language: language, reprocess: false)
                    dismiss()
                }
                Button(L("Enregistrer et retraiter le groupe")) {
                    model.saveGoal(conversation, mode: mode, focus: focus, language: language, reprocess: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help(L("Supprime les fiches et opportunités du groupe et le retraite avec ces consignes."))
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear {
            mode = conversation.mode
            focus = conversation.focus ?? ""
            language = conversation.language
        }
    }
}

struct OpportunityRow: View {
    @Environment(AppModel.self) private var model
    let opportunity: OpportunityRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                ScoreBadge(score: opportunity.score)
                Text(opportunity.summary).font(opportunity.isUnread ? .body.bold() : .body).lineLimit(3)
            }
            HStack {
                Text(model.authorName(ofMessage: opportunity.messageId)).foregroundStyle(.secondary)
                Spacer()
                Text(opportunity.sentAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }
}

struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(.caption.bold().monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .help(L("Adéquation à vos critères, sur 100"))
    }
    private var color: Color { score >= 75 ? .green : score >= 55 ? .orange : .gray }
}

struct OpportunityDetailView: View {
    @Environment(AppModel.self) private var model
    let opportunity: OpportunityRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    ScoreBadge(score: opportunity.score)
                    Text(opportunity.summary).font(.title2.bold()).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Pourquoi ça correspond")).font(.headline)
                    Text(opportunity.reason).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    let contact = model.authorContact(ofMessage: opportunity.messageId)
                    Text(L("Auteur")).font(.headline)
                    HStack(spacing: 12) {
                        Text(contact.name).textSelection(.enabled)
                        if let phone = contact.phone {
                            Text(phone).monospacedDigit().textSelection(.enabled)
                            Button { model.writePrivately(to: phone) } label: {
                                Label(L("Écrire en privé"), systemImage: "bubble.left.and.text.bubble.right")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if contact.phone == nil {
                        Text(L("Cette personne ne partage pas son numéro. Pour lui écrire : dans WhatsApp, ouvrez le groupe, touchez son nom (« \(contact.name) ») puis « Envoyer un message »."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("Dans « \(model.conversationName(opportunity.conversationId)) », le \(opportunity.sentAt.formatted(date: .long, time: .shortened))"))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(L("Message et contexte")).font(.headline)
                ForEach(Array(model.context(ofOpportunity: opportunity).enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(m.author) · \(m.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Text(m.text).textSelection(.enabled)
                            .padding(m.isTarget ? 8 : 0)
                            .background(m.isTarget ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.copyOpportunity(opportunity) } label: { Label(L("Copier le message"), systemImage: "doc.on.doc") }
                Button { model.openWhatsApp() } label: { Label(L("Ouvrir WhatsApp"), systemImage: "message") }
                Button { model.markUnread(itemId: AppModel.itemId(opportunity)) } label: {
                    Label(L("Marquer comme non lue"), systemImage: "envelope.badge")
                }
            }
        }
    }
}
