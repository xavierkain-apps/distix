import DistiXCore
import SwiftUI

/// Groupe de boutons flottant en haut à droite d'une fiche : deux actions et un menu.
struct FloatingActions<MenuContent: View>: View {
    let first: (label: String, help: String, active: Bool, action: () -> Void)
    let second: (label: String, help: String, active: Bool, action: () -> Void)
    @ViewBuilder var menu: MenuContent

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                pillButton(first)
                Rectangle().fill(DS.outline).frame(width: 0.5, height: 16)
                pillButton(second)
            }
            .background(DS.window.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(DS.outline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 30).contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .handCursor()
            .foregroundStyle(DS.accent)
            .background(DS.accentTintStrong, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.accent.opacity(0.3), lineWidth: 0.5))
            .help(L("Actions"))
            .accessibilityLabel(L("Actions"))
        }
    }

    private func pillButton(_ item: (label: String, help: String, active: Bool, action: () -> Void)) -> some View {
        Button(action: item.action) {
            Text(item.label).font(.system(size: 12.5, weight: item.active ? .semibold : .regular))
                .foregroundStyle(item.active ? DS.accent : DS.text)
                .padding(.horizontal, 13).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(item.help)
    }
}

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
            VStack(alignment: .leading, spacing: 26) {
                header
                notices
                if let c {
                    if !c.context.isEmpty {
                        Text(c.context).font(.system(size: 15)).lineSpacing(5).foregroundStyle(DS.text2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if !c.answers.isEmpty { answers(c.answers) }
                    if !c.disagreements.isEmpty || !c.openPoints.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            if !c.disagreements.isEmpty {
                                noteCard(L("Désaccords"), c.disagreements, background: DS.warmCard, ink: DS.warmInk)
                            }
                            if !c.openPoints.isEmpty {
                                noteCard(L("Points ouverts"), c.openPoints, background: DS.greyCard, ink: DS.text3)
                            }
                        }
                    }
                    if !c.links.isEmpty { links(c.links) }
                }
                sources
            }
            .textSelection(.enabled)   // tout le texte de la fiche se sélectionne et se copie
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 64, leading: 40, bottom: 48, trailing: 40))
        }
        .overlay(alignment: .topTrailing) { actions.padding(.top, 12).padding(.trailing, 14) }
        .alert(L("Nouveau thème"), isPresented: $askingTheme) {
            TextField(L("Nom"), text: $newTheme)
            Button(L("Créer")) { if !newTheme.isEmpty { model.setTheme(fiche, name: newTheme) } }
            Button(L("Annuler"), role: .cancel) {}
        }
    }

    // MARK: Actions

    private var actions: some View {
        FloatingActions(
            first: (fiche.review == .validated ? L("Ne plus valider") : L("Valider"),
                    L("Garder cette fiche dans la base de connaissances"), fiche.review == .validated,
                    { model.review(fiche, .validated) }),
            second: (fiche.review == .discarded ? L("Ne plus écarter") : L("Écarter"),
                     L("Retirer cette fiche de la base (elle reste visible dans « Écartées »)"), fiche.review == .discarded,
                     { model.review(fiche, .discarded) })
        ) {
            Button(L("Copier en Markdown")) { model.copyMarkdown(fiche) }
            Button(L("Exporter en .md…")) { model.exportFiche(fiche) }
            Button(L("Marquer comme non lue")) { model.markUnread(fiche.id) }
            Divider()
            Menu(L("Régénérer avec")) {
                ForEach(model.modelChoices) { choice in
                    Button(choice.label) { model.regenerate(fiche, with: choice) }
                }
                if !model.unavailableModelNotes.isEmpty { Divider() }
                ForEach(model.unavailableModelNotes, id: \.self) { Text($0) }
            }
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
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(model.themeName(fiche.themeId)).fontWeight(.semibold).foregroundStyle(DS.accent).layoutPriority(1)
                Text("/").foregroundStyle(DS.text4.opacity(0.6))
                Text(model.conversationName(fiche.conversationId)).fontWeight(.medium).foregroundStyle(DS.text4)
            }
            .font(.system(size: 12)).lineLimit(1)
            Text((showOriginal ? nil : fiche.decodedTranslation?.question) ?? fiche.question)
                .font(.system(size: 28, weight: .bold)).tracking(-0.5).lineSpacing(2).foregroundStyle(DS.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            metaLine
        }
    }

    private var metaLine: some View {
        let count = model.sourceMessages(fiche).count
        var parts: [String] = [Self.range(fiche.firstMessageAt, fiche.lastMessageAt)]
        if count > 0 { parts.append(count == 1 ? L("1 message") : L("\(count) messages")) }
        parts.append(fiche.model.map(Self.modelName) ?? L("modèle non enregistré"))
        var line = Text(MarkdownExporter.statusLabel(fiche.status)).fontWeight(.medium).foregroundColor(DS.text2)
        for part in parts { line = line + Text("  ·  \(part)") }
        if fiche.review == .validated { line = line + Text("  ·  ") + Text(L("Validée")).foregroundColor(DS.green) }
        if fiche.review == .discarded { line = line + Text("  ·  ") + Text(L("Écartée")).foregroundColor(DS.red) }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: DS.statusDot(fiche.status), size: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            line.fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).foregroundStyle(DS.text4)
        .help(fiche.model.map { L("Rédigée par \($0)") } ?? L("Modèle non enregistré (fiche rédigée avant cette information)"))
    }

    /// « 12 – 14 sept. », ou une seule date.
    static func range(_ a: Date, _ b: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(a, inSameDayAs: b) { return DS.listDate(b) }
        if calendar.isDate(a, equalTo: b, toGranularity: .month) {
            return "\(calendar.component(.day, from: a)) – \(DS.listDate(b))"
        }
        return "\(DS.listDate(a)) – \(DS.listDate(b))"
    }

    /// « Claude Code · sonnet » devient « Claude Sonnet ».
    static func modelName(_ raw: String) -> String {
        let parts = raw.components(separatedBy: " · ")
        guard parts.count == 2, parts[0].hasPrefix("Claude") else { return raw }
        return "Claude " + parts[1].capitalized
    }

    // MARK: Bandeaux

    @ViewBuilder
    private var notices: some View {
        let hasMismatch = fiche.translation == nil && model.languageMismatch(fiche) != nil
        let hasTranslation = fiche.translationLanguage != nil && fiche.translation != nil
        let hasChange = fiche.readState == .updated && fiche.changeNote != nil
        if hasMismatch || hasTranslation || hasChange {
            VStack(alignment: .leading, spacing: 8) {
                if hasChange, let note = fiche.changeNote {
                    notice(background: DS.warmCard) {
                        Label(note, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(DS.warmInk)
                    }
                }
                if hasMismatch, let expected = model.languageMismatch(fiche) {
                    notice(background: DS.warmCard) {
                        Text(L("Cette fiche n'est pas en \(FicheLanguage.displayName(expected)), la langue attendue pour ce groupe (fiche rédigée avant la règle de langue)."))
                            .foregroundStyle(DS.text2).frame(maxWidth: .infinity, alignment: .leading)
                        Button(L("Régénérer")) { model.regenerateInExpectedLanguage(fiche) }.buttonStyle(.pillCompact)
                    }
                }
                if hasTranslation, let lang = fiche.translationLanguage {
                    notice(background: DS.accentTint) {
                        Text(showOriginal ? L("Version originale") : L("Traduction en \(FicheLanguage.name(lang))"))
                            .foregroundStyle(DS.accentInk).frame(maxWidth: .infinity, alignment: .leading)
                        Button(showOriginal ? L("Afficher la traduction") : L("Afficher l'original")) { showOriginal.toggle() }
                            .buttonStyle(.plain).foregroundStyle(DS.accent).fontWeight(.medium).handCursor()
                    }
                }
            }
        }
    }

    private func notice<C: View>(background: Color, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 13)).lineSpacing(2)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Contenu

    private func answers(_ list: [FicheAnswer]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CapsLabel(L("Réponses"))
            ForEach(Array(list.enumerated()), id: \.offset) { index, a in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.accent)
                        .frame(width: 22, height: 22).background(DS.accentTint, in: Circle())
                        .frame(width: 26, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.summary).font(.system(size: 14.5)).lineSpacing(3.5).foregroundStyle(DS.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(MarkdownExporter.supportLabel(a.support).capitalizedFirst)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(supportColor(a.support))
                    }
                }
            }
        }
    }

    private func noteCard(_ title: String, _ items: [String], background: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(title, color: ink)
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 13)).lineSpacing(3).foregroundStyle(DS.text2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func links(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(L("Liens"))
            ForEach(list, id: \.self) { l in
                let clean = LinkCleaner.clean(l)
                if let url = URL(string: clean) {
                    Link(destination: url) {
                        Text(clean).font(.system(size: 13)).multilineTextAlignment(.leading).lineLimit(2).truncationMode(.middle)
                    }
                    .foregroundStyle(DS.accent)
                    .handCursor()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(clean)
                } else {
                    Text(clean).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var sources: some View {
        let messages = model.sourceMessages(fiche)
        return VStack(alignment: .leading, spacing: 14) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { showSources.toggle() } } label: {
                HStack(spacing: 10) {
                    Text(messages.count == 1 ? L("Lire le message source") : L("Lire les \(messages.count) messages sources"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.settings.showRealNames ? L("vrais noms") : L("alias")).font(.system(size: 12)).foregroundStyle(DS.text4)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text4)
                        .rotationEffect(.degrees(showSources ? 90 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.outline, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .handCursor()
            .accessibilityLabel(L("Messages sources"))
            if showSources {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                    MessageBlock(author: m.author, date: m.date, text: m.text, highlighted: false)
                }
            }
        }
    }

    private func supportColor(_ s: FicheAnswer.Support) -> Color {
        switch s {
        case .consensus: return DS.green
        case .avis_isole: return DS.blue
        case .conteste: return DS.orange
        }
    }
}

/// Un message source : auteur, heure, texte.
struct MessageBlock: View {
    let author: String
    let date: Date
    let text: String
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(author) · \(DS.listDate(date, time: true))")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(highlighted ? DS.accent : DS.text4)
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(highlighted ? DS.text : DS.text2)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, highlighted ? 12 : 0).padding(.vertical, highlighted ? 10 : 0)
        .background(highlighted ? DS.accentTint : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
