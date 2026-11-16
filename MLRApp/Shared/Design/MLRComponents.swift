import SwiftUI
import Kingfisher

// MARK: - MLR revamp components: USAGE CHEAT-SHEET (read this, not the code)
//
// Backdrop   .mlrBackdrop(_ kind: MLRBackdrop.Kind = .standard)   // .fest for Family Fest; hides scroll bg + transparent nav bar.
//            MLRBackdrop(.standard | .fest)                        // raw view (already applied per tab root; don't re-add on pushed screens)
// Card       MLRCard(_ variant: MLRCardVariant = .plain, padding: CGFloat = 18) { content }
//            variants: .plain  .tinted(Color)  .hero  .fest   (fest = theme card fill + theme border)
//            view.mlrCard(_ variant = .plain, padding: 18)         // same as a modifier
//            view.cardStyle(...)                                   // legacy modifier; now renders the new look (radius 22)
// IconTile   IconTile(symbol: "tent.fill", accent: .mlrPrimary, size: 52)   // size 40 / 52 / 64
//            IconTile(emoji: "🏕️", accent: .mlrCampfire, size: 52)
// Eyebrow    Eyebrow("Up next", color: .mlrCampfire)               // 12 semibold UPPERCASE tracking 1.2; also view.mlrEyebrow(color)
// Header     SectionHeader("Birthdays")                            // serif 22
//            SectionHeader("Events", actionTitle: "See all") { ... }   // trailing pine action
// Buttons    .buttonStyle(.mlrPrimary)  (.mlrDestructive = campfire solid)  .buttonStyle(.mlrSecondary)  .buttonStyle(.mlrQuiet)
//            Primary: 52pt, radius 16, full width; Secondary: pine 10% fill, full width; Quiet: text only.
// Pills      MLRPills(_ items: [ID], selection: Binding<ID>, accent: Color = .mlrPrimary) { id in "Title" }   // ID: Hashable
// Due        RelativeDue(date)  -> campfire "in 6 months"/"tomorrow";  RelativeDue.text(for: Date) -> String
// Avatar     MLRAvatar(name: "Ann Lee", url: "https://...", size: 40, ring: true)   // initials fallback on pine tint
//            AvatarStack([AvatarPerson(id:, name:, url:)], max: 5, size: 28, total: Int? = nil)   // overlapping + "+N"
// Type       fonts: .mlrScreenTitle .mlrSectionTitle .mlrHeroTitle .mlrCardTitle .mlrRowTitle .mlrSecondary .mlrCaption13 .mlrEyebrow
//            Font.festDisplay(size, weight:) (theme heading font else serif); view.mlrScreenTitle()/.mlrSectionTitle()/.mlrCardTitle()/.mlrSecondaryText()
// Colours    Color.mlrText/.mlrTextMuted/.mlrTextFaint, .mlrPrimary/.mlrPineText, .mlrLake/.mlrCampfire/.mlrSun/.mlrDusk,
//            .mlrCard/.mlrBorder/.mlrSurface, fest: .mlrFest(.mlrFestWine) .mlrFestAzure .mlrFestInk .mlrFestCard .mlrFestBorder .mlrFestParchment
// Edit mode  screen root: .mlrEditToggle(canEdit: Bool)  // adds toolbar pencil toggle for the shared store
//            EditPencil(...) (EditorKit) shows only when MLREditModeStore.shared.isOn (app-wide)
// Nav        tab roots already have the backdrop + transparent bars; remove any opaque .background(Color.mlrSurface) on your screen root.

// MARK: - MLRCard

enum MLRCardVariant {
    case plain
    case tinted(Color)
    case hero
    case fest

    var radius: CGFloat {
        if case .hero = self { return 28 }
        return 22
    }
}

private struct MLRCardSurface: ViewModifier {
    let variant: MLRCardVariant
    var padding: CGFloat?

    private var isHero: Bool { if case .hero = variant { return true }; return false }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: variant.radius, style: .continuous)
        content
            .padding(padding ?? 0)
            .background {
                switch variant {
                case .plain, .hero: Color.mlrCard
                case .tinted(let c): ZStack { Color.mlrCard; c.opacity(0.08) }
                case .fest: Color.mlrFestCard
                }
            }
            .clipShape(shape)
            .overlay {
                switch variant {
                case .plain, .hero: shape.strokeBorder(Color.mlrBorder, lineWidth: 1)
                case .tinted(let c): shape.strokeBorder(c.opacity(0.20), lineWidth: 1)
                case .fest: shape.strokeBorder(Color.mlrFestBorder, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(isHero ? 0.10 : 0.06),
                    radius: isHero ? 18 : 10, x: 0, y: isHero ? 8 : 2)
    }
}

struct MLRCard<Content: View>: View {
    var variant: MLRCardVariant
    var padding: CGFloat
    let content: Content

    init(_ variant: MLRCardVariant = .plain, padding: CGFloat = 18,
         @ViewBuilder content: () -> Content) {
        self.variant = variant
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MLRCardSurface(variant: variant, padding: padding))
    }
}

extension View {
    /// The MLR card look as a modifier (padding included; pass 0 for edge-to-edge media).
    func mlrCard(_ variant: MLRCardVariant = .plain, padding: CGFloat = 18) -> some View {
        modifier(MLRCardSurface(variant: variant, padding: padding))
    }
}

// MARK: - IconTile

struct IconTile: View {
    let symbol: String?
    let emoji: String?
    var accent: Color
    var size: CGFloat

    init(symbol: String, accent: Color = .mlrPrimary, size: CGFloat = 52) {
        self.symbol = symbol; self.emoji = nil; self.accent = accent; self.size = size
    }
    init(emoji: String, accent: Color = .mlrPrimary, size: CGFloat = 52) {
        self.symbol = nil; self.emoji = emoji; self.accent = accent; self.size = size
    }

    var body: some View {
        let scale = size / 52
        ZStack {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(accent.opacity(0.12))
            if let emoji {
                Text(emoji).font(.system(size: 28 * scale))
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22 * scale, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Eyebrow / SectionHeader

struct Eyebrow: View {
    let text: String
    var color: Color
    init(_ text: String, color: Color = .mlrCampfire) { self.text = text; self.color = color }
    var body: some View { Text(text).mlrEyebrow(color) }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.actionTitle = actionTitle; self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.mlrSectionTitle).foregroundStyle(Color.mlrText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let action {
                Button(actionTitle ?? "See all", action: action)
                    .font(Font.mlrSecondary.weight(.semibold))
                    .foregroundStyle(Color.mlrPineText)
                    .buttonStyle(.pressable)
            }
        }
    }
}

// MARK: - Button styles

struct MLRFilledButtonStyle: ButtonStyle {
    enum Kind { case primary, destructive, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = kind == .secondary ? .mlrPineText : .white
        let bg: Color = {
            switch kind {
            case .primary: return .mlrPrimary
            case .destructive: return .mlrCampfire
            case .secondary: return Color.mlrPrimary.opacity(0.10)
            }
        }()
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(MLRMotion.spring, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, p in p }
    }
}

struct MLRQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(Color.mlrPineText)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MLRFilledButtonStyle {
    static var mlrPrimary: MLRFilledButtonStyle { MLRFilledButtonStyle(kind: .primary) }
    static var mlrDestructive: MLRFilledButtonStyle { MLRFilledButtonStyle(kind: .destructive) }
    static var mlrSecondary: MLRFilledButtonStyle { MLRFilledButtonStyle(kind: .secondary) }
}
extension ButtonStyle where Self == MLRQuietButtonStyle {
    static var mlrQuiet: MLRQuietButtonStyle { MLRQuietButtonStyle() }
}

// MARK: - MLRPills (segmented pills)

struct MLRPills<ID: Hashable>: View {
    let items: [ID]
    @Binding var selection: ID
    var accent: Color
    let title: (ID) -> String
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ items: [ID], selection: Binding<ID>, accent: Color = .mlrPrimary,
         title: @escaping (ID) -> String) {
        self.items = items; self._selection = selection; self.accent = accent; self.title = title
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        pill(item)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .onChange(of: selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func pill(_ item: ID) -> some View {
        let on = item == selection
        return Button {
            Haptics.select()
            withAnimation(reduceMotion ? nil : MLRMotion.spring) { selection = item }
        } label: {
            Text(title(item))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.mlrText)
                .padding(.horizontal, 16).frame(minHeight: 40)
                .background {
                    if on {
                        Capsule().fill(accent).matchedGeometryEffect(id: "pill", in: ns)
                    } else {
                        Capsule().fill(Color.mlrCard)
                            .overlay(Capsule().strokeBorder(Color.mlrBorder, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .id(item)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - RelativeDue

struct RelativeDue: View {
    let date: Date
    init(_ date: Date) { self.date = date }

    var body: some View {
        Text(Self.text(for: date))
            .font(Font.mlrSecondary.weight(.semibold))
            .foregroundStyle(Color.mlrCampfire)
    }

    /// "today", "tomorrow", "in 5 days", "in 3 weeks", "in 6 months", "in 2 years"; past: "yesterday"/"ended".
    static func text(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<(-1): return "ended"
        case -1: return "yesterday"
        case 0: return "today"
        case 1: return "tomorrow"
        case 2..<14: return "in \(days) days"
        case 14..<60: return "in \(days / 7) weeks"
        case 60..<730:
            let m = Swift.max(2, cal.dateComponents([.month], from: now, to: date).month ?? days / 30)
            return "in \(m) months"
        default: return "in \(days / 365) years"
        }
    }
}

// MARK: - Avatars

struct MLRAvatar: View {
    let name: String
    var url: String?
    var size: CGFloat
    var ring: Bool

    init(name: String, url: String? = nil, size: CGFloat = 40, ring: Bool = true) {
        self.name = name; self.url = url; self.size = size; self.ring = ring
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                KFImage(u).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.mlrPrimary.opacity(0.14)
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(Color.mlrPineText)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { if ring { Circle().strokeBorder(Color.white, lineWidth: 2) } }
        .accessibilityLabel(name)
    }
}

struct AvatarPerson: Identifiable, Hashable {
    let id: String
    var name: String
    var url: String?
    init(id: String, name: String, url: String? = nil) { self.id = id; self.name = name; self.url = url }
}

struct AvatarStack: View {
    let people: [AvatarPerson]
    var maxShown: Int
    var size: CGFloat
    /// Total going when `people` is only a sample; defaults to people.count.
    var total: Int?

    init(_ people: [AvatarPerson], max: Int = 5, size: CGFloat = 28, total: Int? = nil) {
        self.people = people; self.maxShown = max; self.size = size; self.total = total
    }

    var body: some View {
        let shown = Array(people.prefix(maxShown))
        let count = total ?? people.count
        HStack(spacing: 8) {
            HStack(spacing: -size * 0.32) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                    MLRAvatar(name: p.name, url: p.url, size: size).zIndex(Double(shown.count - i))
                }
            }
            if count > 0 {
                Text(count > shown.count ? "+\(count - shown.count)" : "\(count)")
                    .font(.mlrCaption13.weight(.semibold))
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) going")
    }
}

// MARK: - Edit mode

/// ONE app-wide Edit switch. Environment does not flow into pushed destinations,
/// so the state lives in a shared store; each screen with `EditPencil`s adds
/// `.mlrEditToggle(canEdit:)`. Reset on sign-out and when an admin previews as someone else.
@Observable
final class MLREditModeStore {
    static let shared = MLREditModeStore()
    var isOn = false
}

private struct MLREditToggleModifier: ViewModifier {
    let canEdit: Bool
    var tint: Color = .mlrPineText
    private var store: MLREditModeStore { .shared }

    func body(content: Content) -> some View {
        content.toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.select()
                        withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { store.isOn.toggle() }
                    } label: {
                        if store.isOn {
                            Text("Done").fontWeight(.semibold).foregroundStyle(tint)
                        } else {
                            Image(systemName: "pencil").fontWeight(.semibold).foregroundStyle(tint)
                        }
                    }
                    .accessibilityLabel(store.isOn ? "Finish editing" : "Edit this screen")
                }
            }
        }
    }
}

extension View {
    /// Toolbar Edit toggle for the app-wide edit switch; shown only when `canEdit`.
    func mlrEditToggle(canEdit: Bool, tint: Color = .mlrPineText) -> some View { modifier(MLREditToggleModifier(canEdit: canEdit, tint: tint)) }
}


// MARK: - CardLink
/// A NavigationLink for a card-style `List` row. The system disclosure chevron
/// would sit outside the card, so the link is an invisible sibling and the row
/// (which draws its own in-card chevron, if any) is the visible content.
struct CardLink<Destination: View, Label: View>: View {
    @ViewBuilder var destination: () -> Destination
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            NavigationLink { destination() } label: { EmptyView() }.opacity(0)
            label()
        }
    }
}
