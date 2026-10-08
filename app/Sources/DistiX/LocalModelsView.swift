import DistiXCore
import SwiftUI

/// Modèles d'IA locaux (Ollama) : détection, liste, téléchargement.
struct LocalModelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var downloading: String?
    @State private var progress = 0.0
    @State private var stepText = ""
    @State private var error: String?

    var body: some View {
        SettingsSection(L("Modèles locaux (Ollama)")) {
            HStack(spacing: 5) {
                StatusDot(color: model.ollamaRunning ? DS.greenDot : DS.greyDot)
                Text(model.ollamaRunning ? L("Ollama est lancé") : L("Ollama n'est pas lancé"))
            }
            .font(.system(size: 11.5)).foregroundStyle(model.ollamaRunning ? DS.green : DS.text4)
        } content: {
            if !model.ollamaRunning {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Pour utiliser une IA qui tourne entièrement sur ce Mac, installez Ollama (gratuit), lancez-le, puis revenez ici."))
                        .font(.system(size: 13)).lineSpacing(2).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L("Télécharger Ollama")) { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
                            .buttonStyle(.pillCompact)
                        Button(L("Vérifier à nouveau")) { Task { await model.refreshLocalModels() } }.buttonStyle(.pillCompact)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
            } else {
                CardRows {
                    ForEach(OllamaClient.recommended) { r in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.label).font(.system(size: 13)).foregroundStyle(DS.text)
                                Text(r.size).font(.system(size: 11.5)).foregroundStyle(DS.text4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if isInstalled(r.id) {
                                Text(L("Installé")).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.green)
                            } else if downloading == r.id {
                                ProgressView(value: progress).tint(DS.accent).frame(width: 110)
                                Text("\(Int(progress * 100)) %").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(DS.text4)
                                    .frame(width: 36, alignment: .trailing)
                            } else {
                                Button(L("Télécharger")) { download(r.id) }.buttonStyle(.pillCompact).disabled(downloading != nil)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    let others = model.localModels.filter { name in !OllamaClient.recommended.contains { isSame($0.id, name) } }
                    if !others.isEmpty {
                        FormRow(L("Autres modèles installés"), subtitle: others.joined(separator: ", ")) { EmptyView() }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if downloading != nil, !stepText.isEmpty { Text(stepText) }
                    if let error { Text(error).foregroundStyle(DS.red) }
                    Text(L("Un modèle local tourne entièrement sur ce Mac. Pour l'utiliser, choisissez « Modèle local ou compatible OpenAI » ci-dessus, ou servez-vous-en pour régénérer une seule fiche."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(DS.text4).padding(.horizontal, 4)
            }
        }
        .task { await model.refreshLocalModels() }
    }

    private func isSame(_ id: String, _ installed: String) -> Bool {
        installed == id || installed.hasPrefix(id + ":") || installed == id + ":latest"
    }

    private func isInstalled(_ id: String) -> Bool {
        model.localModels.contains { isSame(id, $0) }
    }

    private func download(_ id: String) {
        downloading = id
        progress = 0
        error = nil
        Task {
            do {
                try await OllamaClient().pull(id) { fraction, step in
                    Task { @MainActor in
                        progress = fraction
                        stepText = step
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
            await model.refreshLocalModels()
        }
    }
}

/// Présentation simple des fonctionnalités, au premier lancement et depuis le menu Aide.
struct FeatureTour: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Page { let icon: String; let title: String; let text: String }

    private var pages: [Page] {
        [
            Page(icon: "text.book.closed", title: L("Bienvenue dans DistiX"),
                 text: L("DistiX lit, sur votre Mac et en lecture seule, les groupes WhatsApp que vous choisissez, et en tire l'essentiel : vous n'avez plus à tout lire.")),
            Page(icon: "rectangle.stack", title: L("Des fiches au lieu de fils de messages"),
                 text: L("Chaque question devient une fiche : le contexte, les réponses, ce qui fait consensus et ce qui est débattu. Les fiches sont classées par thème et cherchables. Les questions qui reviennent enrichissent la même fiche.")),
            Page(icon: "target", title: L("Un objectif par groupe et par thème"),
                 text: L("Dites ce qui vous intéresse dans chaque groupe, ou créez un thème avec son propre objectif. En mode veille, DistiX ne retient que les messages qui correspondent à ce que vous cherchez ou proposez, par exemple des locataires pour votre appartement.")),
            Page(icon: "checkmark.seal", title: L("Votre base, triée par vous"),
                 text: L("Validez les fiches utiles, écartez les autres : la base validée s'exporte en Markdown pour Notion ou Obsidian. Une fiche mal comprise peut être régénérée avec un autre modèle, y compris un modèle local.")),
            Page(icon: "lock.shield", title: L("Vos données restent chez vous"),
                 text: L("Tout est stocké sur ce Mac. Seul le texte des groupes choisis part vers l'IA, avec les noms remplacés par des alias et les numéros masqués. DistiX n'écrit jamais rien dans WhatsApp.")),
        ]
    }

    var body: some View {
        let p = pages[page]
        VStack(spacing: 0) {
            Group {
                if page == 0 {
                    AppIconView(size: 88, shadow: true)
                } else {
                    Image(systemName: p.icon).font(.system(size: 38, weight: .medium)).foregroundStyle(DS.accent)
                        .frame(width: 88, height: 88)
                        .background(DS.accentTint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            Text(p.title).font(.system(size: 26, weight: .bold)).tracking(-0.5).foregroundStyle(DS.text)
                .multilineTextAlignment(.center).padding(.top, 24)
            Text(p.text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(DS.text3).multilineTextAlignment(.center)
                .frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Capsule().fill(i == page ? DS.accent : DS.text4.opacity(0.4)).frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: page)
            .accessibilityElement().accessibilityLabel(L("Page \(page + 1) sur \(pages.count)"))
            HStack(spacing: 10) {
                if page > 0 { Button(L("Précédent")) { page -= 1 }.buttonStyle(.pill) }
                Spacer()
                if page < pages.count - 1 {
                    Button(L("Passer")) { onFinish() }.buttonStyle(.pillLink)
                    Button(L("Suivant")) { page += 1 }.buttonStyle(.pillPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button(L("C'est parti")) { onFinish() }.buttonStyle(.pillPrimary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 20)
        }
        .padding(EdgeInsets(top: 44, leading: 40, bottom: 24, trailing: 40))
        .frame(width: 600, height: 440)
        .dsSheet()
    }
}
