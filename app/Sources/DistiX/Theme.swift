import AppKit
import SwiftUI

/// Identité visuelle de DistiX (direction « pétrole ») : couleurs, boutons, cartes et icône.
enum DS {
    static let accent = Color(light: 0x0E6873, dark: 0x4FB3BF)
    static let accentTint = Color(light: 0xE0EEEF, dark: 0x1D3A3E)
    static let accentTintStrong = Color(light: 0xDCEBEC, dark: 0x24484D)
    static let accentInk = Color(light: 0x0A4E57, dark: 0xA9DCE1)
    static let accentDisabled = Color(light: 0xA9CDD1, dark: 0x2C4C50)

    static let window = Color(light: 0xF6F5F2, dark: 0x1D1D1B)
    static let card = Color(light: 0xFFFFFF, dark: 0x2A2A28)
    static let sidebar = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.72, darkAlpha: 0.06)
    static let fill = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
    static let fillStrong = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.10)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    static let outline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.16)
    static let chipActive = Color(light: 0x1D1D1F, dark: 0xF2F2F2)
    static let chipActiveText = Color(light: 0xFFFFFF, dark: 0x1D1D1F)
    static let warmCard = Color(light: 0xFBF7EF, dark: 0x35301F)
    static let greyCard = Color(light: 0xF5F5F7, dark: 0x323230)

    static let text = Color(light: 0x1D1D1F, dark: 0xF2F2F2)
    static let text2 = Color(light: 0x3A3A3C, dark: 0xD4D4D6)
    static let text3 = Color(light: 0x6E6E73, dark: 0xA6A6AB)
    static let text4 = Color(light: 0x86868B, dark: 0x8E8E93)

    static let green = Color(light: 0x1F8F45, dark: 0x4CC773)
    static let greenDot = Color(hex: 0x30B158)
    static let orange = Color(light: 0xB86200, dark: 0xF0A040)
    static let orangeDot = Color(hex: 0xFF9F0A)
    static let warmInk = Color(light: 0xA0620A, dark: 0xE0A860)
    static let blue = Color(light: 0x0A64D8, dark: 0x5AA2F5)
    static let blueDot = Color(hex: 0x0A84FF)
    static let greyDot = Color(hex: 0x8E8E93)
    static let red = Color(light: 0xD93025, dark: 0xF2675E)

    /// Couleurs des pastilles de groupe (base de connaissances), stables par groupe.
    static let groupDots: [Color] = [greenDot, blueDot, Color(hex: 0xAF52DE), Color(hex: 0xFF375F), Color(hex: 0x64D2FF), Color(hex: 0xFFD60A)]

    static func scoreColors(_ score: Int) -> (background: Color, text: Color) {
        if score >= 75 { return (Color(hex: 0x34C759).opacity(0.15), green) }
        if score >= 55 { return (Color(hex: 0xFF9F0A).opacity(0.16), orange) }
        return (Color(hex: 0x8E8E93).opacity(0.16), text3)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// Couleur qui suit l'apparence claire ou sombre.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: Curseur

/// Curseur en forme de main au survol d'un élément cliquable.
struct HandCursor: ViewModifier {
    var enabled = true

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            content
                .onHover { inside in
                    if inside && enabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .onDisappear { NSCursor.arrow.set() }
        }
    }
}

extension View {
    /// À poser sur tout ce qui se clique : boutons dessinés, lignes de liste, menus, liens.
    func handCursor(_ enabled: Bool = true) -> some View { modifier(HandCursor(enabled: enabled)) }
}

// MARK: Boutons

/// Bouton en pilule : principal (pétrole), secondaire (gris), destructif ou simple lien.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, link, destructiveLink }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isLink = kind == .link || kind == .destructiveLink
        configuration.label
            .font(.system(size: compact ? 12.5 : 13, weight: kind == .primary ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, isLink ? (compact ? 4 : 14) : (compact ? 12 : (kind == .primary ? 18 : 16)))
            .padding(.vertical, compact ? 4 : 7)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .handCursor(isEnabled)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: return .white
        case .secondary: return isEnabled ? DS.text : DS.text4
        case .link: return isEnabled ? DS.accent : DS.text4
        case .destructiveLink: return DS.red
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return isEnabled ? DS.accent : DS.accentDisabled
        case .destructive: return DS.red
        case .secondary: return DS.fillStrong
        case .link, .destructiveLink: return .clear
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillPrimary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var pillLink: PillButtonStyle { PillButtonStyle(kind: .link) }
    static var pillCompact: PillButtonStyle { PillButtonStyle(compact: true) }
}

/// Puce de filtre ou de suggestion.
struct ChipStyle: ButtonStyle {
    enum Kind { case filter, suggestion }
    var kind: Kind = .filter
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .filter ? 12 : 12.5, weight: selected ? .medium : .regular))
            .lineLimit(1)
            .padding(.horizontal, kind == .filter ? 10 : 12)
            .padding(.vertical, kind == .filter ? 4 : 5)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay { if kind == .suggestion && !selected { Capsule().strokeBorder(DS.outline, lineWidth: 0.5) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .handCursor()
    }

    private var foreground: Color {
        guard selected else { return kind == .filter ? DS.text2 : DS.text }
        return kind == .filter ? DS.chipActiveText : .white
    }

    private var background: Color {
        if selected { return kind == .filter ? DS.chipActive : DS.accent }
        return kind == .filter ? DS.fill : DS.card
    }
}

/// Sélecteur à segments arrondis (historique, mode du groupe, onglets des réglages).
struct SegmentedPills<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var capsule = false
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: fontSize, weight: isOn ? (capsule ? .semibold : .medium) : .regular))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: capsule ? 14 : 6, style: .continuous).fill(DS.card)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.fillStrong, in: RoundedRectangle(cornerRadius: capsule ? 16 : 8, style: .continuous))
    }
}

// MARK: Cartes et textes

extension View {
    /// Carte blanche à coins arrondis, avec un filet très léger.
    func dsCard(radius: CGFloat = 12, outline: Color = DS.hairline) -> some View {
        background(DS.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(outline, lineWidth: 0.5))
    }

    /// Fond chaud des feuilles et des fenêtres.
    func dsSheet() -> some View {
        background(DS.window).tint(DS.accent)
    }
}

/// Intertitre en petites capitales espacées.
struct CapsLabel: View {
    let text: String
    var color: Color = DS.text4
    init(_ text: String, color: Color = DS.text4) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "fr_FR")))
            .font(.system(size: 11, weight: .bold)).tracking(0.9).foregroundStyle(color)
    }
}

/// Groupe de lignes de formulaire dans une carte, séparées par des filets.
struct CardRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        _VariadicView.Tree(CardRowsLayout()) { content }
            .dsCard()
    }
}

private struct CardRowsLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                if index > 0 { Rectangle().fill(DS.hairline).frame(height: 0.5) }
                child
            }
        }
    }
}

/// Ligne « libellé à gauche, réglage à droite ».
struct FormRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(DS.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(DS.text4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Champ de recherche ou de filtre arrondi.
struct RoundSearchField: View {
    let prompt: String
    @Binding var text: String
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text4)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.text4) }
                    .buttonStyle(.plain).handCursor().accessibilityLabel(L("Effacer"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(DS.fill, in: Capsule())
    }
}

/// Point d'état (rond) ou carré (veille).
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var square = false
    var body: some View {
        RoundedRectangle(cornerRadius: square ? 2 : size / 2).fill(color).frame(width: size, height: size)
    }
}

// MARK: Icône

/// Icône de DistiX dessinée : bulle de conversation et X, sur fond pétrole.
struct AppIconView: View {
    var size: CGFloat = 88
    var shadow = false

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 140
            context.scaleBy(x: s, y: s)
            AppIconArt.draw(in: &context)
        }
        .frame(width: size, height: size)
        .shadow(color: shadow ? Color(hex: 0x0B5761, alpha: 0.35) : .clear, radius: size * 0.09, y: size * 0.07)
        .accessibilityHidden(true)
    }
}

enum AppIconArt {
    /// Dessin sur une grille de 140 points.
    static func draw(in context: inout GraphicsContext) {
        let square = Path(roundedRect: CGRect(x: 0, y: 0, width: 140, height: 140), cornerRadius: 32, style: .continuous)
        context.fill(square, with: .linearGradient(Gradient(colors: [Color(hex: 0x14808C), Color(hex: 0x0B5761)]),
                                                   startPoint: CGPoint(x: 70, y: 0), endPoint: CGPoint(x: 70, y: 140)))
        context.fill(bubble, with: .color(.white))
        context.fill(bar(angle: 45), with: .color(Color(hex: 0x0E6873)))
        context.fill(bar(angle: -45), with: .color(Color(hex: 0x4FA3AD)))
    }

    /// Bulle ronde et sa queue, en bas à gauche.
    static var bubble: Path {
        var path = Path(ellipseIn: CGRect(x: 28, y: 22, width: 84, height: 84))
        var tail = Path()
        tail.move(to: CGPoint(x: 27, y: 86))
        tail.addLine(to: CGPoint(x: 44, y: 86))
        tail.addLine(to: CGPoint(x: 27, y: 110))
        tail.closeSubpath()
        path.addPath(tail.applying(rotation(18, around: CGPoint(x: 35.5, y: 98))))
        return path
    }

    static func bar(angle: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: 49, y: 59, width: 42, height: 10), cornerRadius: 5)
            .applying(rotation(angle, around: CGPoint(x: 70, y: 64)))
    }

    static func rotation(_ degrees: CGFloat, around c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y).rotated(by: degrees * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }

    /// Pictogramme monochrome pour la barre des menus (bulle pleine, X évidé).
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 17, height: 16), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.translateBy(x: 0.5, y: 0.5)
            cg.scaleBy(x: 15.0 / 100, y: 15.0 / 100)
            // Bulle ramenée dans un carré de 100 : même tracé que l'icône, sans le fond.
            let fit = CGAffineTransform(translationX: -20, y: -17).scaledBy(x: 1, y: 1)
            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(bubble.applying(fit).cgPath)
            cg.fillPath()
            cg.setBlendMode(.destinationOut)
            for angle in [CGFloat(45), -45] {
                let thick = Path(roundedRect: CGRect(x: 47, y: 57, width: 46, height: 14), cornerRadius: 7)
                    .applying(rotation(angle, around: CGPoint(x: 70, y: 64)))
                cg.addPath(thick.applying(fit).cgPath)
                cg.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: Fenêtre

/// Donne accès à la fenêtre AppKit d'une vue pour régler ce que SwiftUI n'expose pas.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { configure(window) } }
    }
}

/// Place les boutons de fenêtre dans le panneau flottant de la barre latérale, et les y maintient.
final class TrafficLightPositioner: NSObject {
    static let shared = TrafficLightPositioner()
    private var observed = Set<ObjectIdentifier>()
    /// Bord gauche du premier bouton et centre vertical, depuis le coin haut gauche de la fenêtre.
    private let leading: CGFloat = 24
    private let centerFromTop: CGFloat = 28
    private let spacing: CGFloat = 20

    func attach(to window: NSWindow) {
        apply(window)
        guard observed.insert(ObjectIdentifier(window)).inserted else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                if let w = note.object as? NSWindow { self?.apply(w) }
            }
        }
    }

    private func apply(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, kind) in kinds.enumerated() {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            let y = container.isFlipped ? centerFromTop - button.frame.height / 2
                                        : container.frame.height - centerFromTop - button.frame.height / 2
            button.setFrameOrigin(NSPoint(x: leading + CGFloat(index) * spacing, y: y))
        }
    }
}
