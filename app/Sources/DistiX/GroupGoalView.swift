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
    /// Une consigne par mode : passer en veille ne réutilise pas les consignes de la base.
    @State private var texts: [GroupMode: String] = [:]
    private var focusBinding: Binding<String> {
        Binding(get: { texts[mode] ?? "" }, set: { texts[mode] = $0 })
    }
    private var focus: String { texts[mode] ?? "" }
    @State private var language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Objectif du groupe")).font(.system(size: 22, weight: .bold)).tracking(-0.4).foregroundStyle(DS.text)
                    Text(conversation.name).font(.system(size: 13)).foregroundStyle(DS.text4).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SegmentedPills(selection: $mode,
                               options: [(GroupMode.knowledge, L("Base de connaissances")), (GroupMode.watch, L("Veille"))],
                               fontSize: 12.5, horizontalPadding: 14, verticalPadding: 4)
            }
            Text(mode == .knowledge
                 ? L("Les échanges deviennent des fiches classées par thème. Précisez, si vous le souhaitez, ce qui vous intéresse dans ce groupe.")
                 : L("Seuls les messages qui correspondent à vos critères sont retenus, en opportunités notées sur 100. Décrivez précisément ce que vous cherchez ou proposez."))
                .font(.system(size: 13)).lineSpacing(2).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                CapsLabel(L("Suggestions"))
                HStack(spacing: 6) {
                    ForEach(GoalTemplate.list(for: mode)) { t in
                        Button(t.title) { texts[mode] = t.text }
                            .buttonStyle(ChipStyle(kind: .suggestion, selected: !t.text.isEmpty && focus == t.text))
                    }
                }
            }
            CardEditor(text: focusBinding, minHeight: 120)
            if mode == .watch && focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(L("Sans critères, la veille ne retient rien."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5)).foregroundStyle(DS.orange)
            }
            Text(L("Ces consignes sont envoyées à l'IA avec les messages du groupe. Remplacez les passages entre crochets."))
                .font(.system(size: 12)).foregroundStyle(DS.text4)
            if mode == .knowledge {
                CardRows {
                    FormRow(L("Langue des fiches")) {
                        Picker(L("Langue des fiches"), selection: $language) {
                            Text(L("Par défaut (\(model.settings.ficheLanguage.isEmpty ? L("langue d'origine") : FicheLanguage.name(model.settings.ficheLanguage)))"))
                                .tag(String?.none)
                            Text(L("Langue d'origine de la conversation")).tag(String?.some(FicheLanguage.original))
                            ForEach(FicheLanguage.choices, id: \.code) { Text($0.name.capitalized).tag(String?.some($0.code)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("Annuler")) { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button(L("Enregistrer")) {
                    model.saveGoal(conversation, mode: mode, focus: focus, language: language, reprocess: false)
                    dismiss()
                }
                .buttonStyle(.pill)
                Button(L("Enregistrer et retraiter le groupe")) {
                    model.saveGoal(conversation, mode: mode, focus: focus, language: language, reprocess: true)
                    dismiss()
                }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
                .help(L("Supprime les fiches et opportunités du groupe et le retraite avec ces consignes."))
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 22, trailing: 28))
        .frame(width: 680)
        .dsSheet()
        .onAppear {
            mode = conversation.mode
            texts[conversation.mode] = conversation.focus ?? ""
            language = conversation.language
        }
    }
}

struct OpportunityRow: View {
    @Environment(AppModel.self) private var model
    let opportunity: OpportunityRecord
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScoreBadge(score: opportunity.score)
            VStack(alignment: .leading, spacing: 5) {
                Text(opportunity.summary).font(.system(size: 13.5, weight: .semibold)).lineSpacing(1.5).lineLimit(4)
                    .foregroundStyle(DS.text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if opportunity.isUnread { Text(L("Nouveau")).fontWeight(.semibold).foregroundStyle(DS.accent); Text("·") }
                    Text("\(model.authorName(ofMessage: opportunity.messageId)) · \(DS.listDate(opportunity.sentAt, time: true))").lineLimit(1)
                }
                .font(.system(size: 11)).foregroundStyle(DS.text4)
            }
        }
        .modifier(ListCard(selected: selected))
    }
}

/// Note d'adéquation sur 100, en carré coloré.
struct ScoreBadge: View {
    let score: Int
    var body: some View {
        let colors = DS.scoreColors(score)
        Text("\(score)")
            .font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(colors.text)
            .frame(width: 38, height: 38)
            .background(colors.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help(L("Adéquation à vos critères, sur 100"))
            .accessibilityLabel(L("Adéquation \(score) sur 100"))
    }
}

struct OpportunityDetailView: View {
    @Environment(AppModel.self) private var model
    let opportunity: OpportunityRecord

    var body: some View {
        let colors = DS.scoreColors(opportunity.score)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text("\(opportunity.score) / 100").font(.system(size: 13, weight: .bold)).monospacedDigit()
                            .foregroundStyle(colors.text).padding(.horizontal, 9).padding(.vertical, 3)
                            .background(colors.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(L("Adéquation à vos critères")).font(.system(size: 12)).foregroundStyle(DS.text4)
                    }
                    Text(opportunity.summary).font(.system(size: 28, weight: .bold)).tracking(-0.5).lineSpacing(2)
                        .foregroundStyle(DS.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    CapsLabel(L("Pourquoi ça correspond"))
                    Text(opportunity.reason).font(.system(size: 15)).lineSpacing(5).foregroundStyle(DS.text2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                contactCard
                VStack(alignment: .leading, spacing: 14) {
                    CapsLabel(L("Message et contexte"))
                    ForEach(Array(model.context(ofOpportunity: opportunity).enumerated()), id: \.offset) { _, m in
                        MessageBlock(author: m.author, date: m.date, text: m.text, highlighted: m.isTarget)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 64, leading: 40, bottom: 48, trailing: 40))
        }
        .overlay(alignment: .topTrailing) {
            FloatingActions(
                first: (L("Copier le message"), L("Copier le résumé, l'auteur et le message"), false, { model.copyOpportunity(opportunity) }),
                second: (L("Ouvrir WhatsApp"), L("Ouvrir WhatsApp"), false, { model.openWhatsApp() })
            ) {
                Button(L("Marquer comme non lue")) { model.markUnread(itemId: AppModel.itemId(opportunity)) }
            }
            .padding(.top, 12).padding(.trailing, 14)
        }
    }

    private var contactCard: some View {
        let contact = model.authorContact(ofMessage: opportunity.messageId)
        let when = L("le \(opportunity.sentAt.formatted(Date.FormatStyle().day().month(.wide).locale(Locale(identifier: "fr_FR")))) à \(opportunity.sentAt.formatted(date: .omitted, time: .shortened))")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(Self.initials(contact.name)).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.accent)
                    .frame(width: 40, height: 40).background(DS.accentTintStrong, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).textSelection(.enabled)
                    Text([contact.phone, when].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text4).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let phone = contact.phone {
                    Button(L("Écrire en privé")) { model.writePrivately(to: phone) }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: false))
                }
            }
            if contact.phone == nil {
                Text(L("Cette personne ne partage pas son numéro. Pour lui écrire : dans WhatsApp, ouvrez le groupe, touchez son nom (« \(contact.name) ») puis « Envoyer un message »."))
                    .font(.system(size: 12)).lineSpacing(2).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Dans « \(model.conversationName(opportunity.conversationId)) »"))
                .font(.system(size: 12)).foregroundStyle(DS.text4)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(DS.window, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// « Camille R. » donne « CR ».
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
