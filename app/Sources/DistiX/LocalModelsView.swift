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
        Section(L("Modèles locaux (Ollama)")) {
            if !model.ollamaRunning {
                Text(L("Pour utiliser une IA qui tourne entièrement sur ce Mac, installez Ollama (gratuit), lancez-le, puis revenez ici."))
                    .font(.callout)
                HStack {
                    Button(L("Télécharger Ollama")) { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
                    Button(L("Vérifier à nouveau")) { Task { await model.refreshLocalModels() } }
                }
            } else {
                if model.localModels.isEmpty {
                    Text(L("Ollama est lancé, aucun modèle installé.")).font(.callout)
                } else {
                    LabeledContent(L("Installés"), value: model.localModels.joined(separator: ", "))
                }
                ForEach(OllamaClient.recommended) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.label)
                            Text(r.size).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.localModels.contains(where: { $0 == r.id || $0.hasPrefix(r.id + ":") || $0 == r.id + ":latest" }) {
                            Label(L("Installé"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if downloading == r.id {
                            ProgressView(value: progress).frame(width: 120)
                        } else {
                            Button(L("Télécharger")) { download(r.id) }.disabled(downloading != nil)
                        }
                    }
                }
                if downloading != nil { Text(stepText).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text(L("Pour l'utiliser : choisissez « Modèle local ou compatible OpenAI » ci-dessus avec l'adresse http://localhost:11434/v1 et le nom du modèle, ou servez-vous-en pour régénérer une fiche."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await model.refreshLocalModels() }
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
        VStack(spacing: 18) {
            Image(systemName: p.icon).font(.system(size: 52)).foregroundStyle(Color.accentColor).padding(.top, 24)
            Text(p.title).font(.title.bold()).multilineTextAlignment(.center)
            Text(p.text).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            HStack {
                if page > 0 { Button(L("Précédent")) { page -= 1 } }
                Spacer()
                if page < pages.count - 1 {
                    Button(L("Passer")) { onFinish() }.buttonStyle(.link)
                    Button(L("Suivant")) { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("C'est parti")) { onFinish() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 600, height: 440)
    }
}
