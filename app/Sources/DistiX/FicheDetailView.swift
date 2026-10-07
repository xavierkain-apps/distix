import DistiXCore
import SwiftUI

struct FicheDetailView: View {
    @Environment(AppModel.self) private var model
    let fiche: FicheRecord
    @State private var showSources = false
    @State private var newTheme = ""
    @State private var askingTheme = false
    @State private var showOriginal = false

    var body: some View {
        let c = showOriginal ? fiche.decoded : (fiche.decodedTranslation ?? fiche.decoded)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let lang = fiche.translationLanguage, fiche.translation != nil {
                    HStack {
                        Label(showOriginal ? L("Version originale") : L("Traduction en \(FicheLanguage.name(lang))"),
                              systemImage: "character.book.closed")
                        Button(showOriginal ? L("Afficher la traduction") : L("Afficher l'original")) { showOriginal.toggle() }
                            .buttonStyle(.link)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                if let c {
                    if !c.context.isEmpty {
                        section(L("Contexte")) { Text(c.context).textSelection(.enabled) }
                    }
                    if !c.answers.isEmpty {
                        section(L("Réponses")) {
                            ForEach(Array(c.answers.enumerated()), id: \.offset) { _, a in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(MarkdownExporter.supportLabel(a.support))
                                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(supportColor(a.support).opacity(0.18), in: Capsule())
                                        .foregroundStyle(supportColor(a.support))
                                    Text(a.summary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    list(L("Désaccords"), c.disagreements)
                    list(L("Points ouverts"), c.openPoints)
                    if !c.links.isEmpty {
                        section(L("Liens")) {
                            ForEach(c.links, id: \.self) { l in
                                if let url = URL(string: l) { Link(l, destination: url) } else { Text(l) }
                            }
                        }
                    }
                }
                Divider()
                DisclosureGroup(isExpanded: $showSources) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.sourceMessages(fiche).enumerated()), id: \.offset) { _, m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(m.author) · \(m.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                Text(m.text).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(model.settings.showRealNames ? L("Messages sources") : L("Messages sources (alias)")).font(.headline)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.copyMarkdown(fiche) } label: { Label(L("Copier en Markdown"), systemImage: "doc.on.doc") }
                    .help(L("Copier en Markdown"))
                Menu {
                    Button(L("Exporter en .md…")) { model.exportFiche(fiche) }
                    Button(L("Marquer comme non lue")) { model.markUnread(fiche.id) }
                    Menu(L("Traduire en")) {
                        ForEach(FicheLanguage.choices, id: \.code) { lang in
                            Button(lang.name.capitalized) { showOriginal = false; model.translate(fiche, to: lang.code) }
                        }
                    }
                    Menu(L("Changer de thème")) {
                        ForEach(model.themes[fiche.conversationId] ?? []) { t in
                            Button(t.name) { model.setTheme(fiche, name: t.name) }
                        }
                        Divider()
                        Button(L("Nouveau thème…")) { newTheme = ""; askingTheme = true }
                    }
                    if model.isMerged(fiche) {
                        Divider()
                        Button(L("Défaire la fusion")) { model.undoMerge(fiche) }
                    }
                } label: {
                    Label(L("Actions"), systemImage: "ellipsis.circle")
                }
            }
        }
        .alert(L("Nouveau thème"), isPresented: $askingTheme) {
            TextField(L("Nom"), text: $newTheme)
            Button(L("Créer")) { if !newTheme.isEmpty { model.setTheme(fiche, name: newTheme) } }
            Button(L("Annuler"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((showOriginal ? nil : fiche.decodedTranslation?.question) ?? fiche.question).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 10) {
                StatusBadge(status: fiche.status)
                Text(model.themeName(fiche.themeId))
                Text("·")
                Text(model.conversationName(fiche.conversationId))
                Spacer()
                Text(L("Du \(fiche.firstMessageAt.formatted(date: .abbreviated, time: .omitted)) au \(fiche.lastMessageAt.formatted(date: .abbreviated, time: .omitted))"))
            }
            .font(.callout).foregroundStyle(.secondary)
            if fiche.readState == .updated, let note = fiche.changeNote {
                Label(note, systemImage: "arrow.triangle.2.circlepath").font(.callout)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            section(title) {
                ForEach(items, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
        }
    }

    private func supportColor(_ s: FicheAnswer.Support) -> Color {
        switch s {
        case .consensus: return .green
        case .avis_isole: return .blue
        case .conteste: return .orange
        }
    }
}
