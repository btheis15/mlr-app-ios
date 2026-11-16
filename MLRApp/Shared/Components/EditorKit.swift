import SwiftUI
import PhotosUI
import Kingfisher
import Supabase

// MARK: - EditorKit
//
// One shared way to build admin/editor screens so every save behaves the same:
// real error messages, unsaved-changes guard, haptics, native date/time/colour
// pickers, reorderable lists with confirm-and-undo deletes.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   struct ThingSheet: View {
//       @Environment(AppEnvironment.self) private var env
//       @State private var draft: EditorDraft<Thing>
//       init(thing: Thing) { _draft = State(initialValue: EditorDraft(thing)) }
//
//       var body: some View {
//           EditorSheet(title: "Edit thing",
//                       isDirty: draft.isDirty,
//                       canSave: !draft.value.title.isEmpty,
//                       save: { try await env.thingService.save(draft.value) }) {
//               Section("Basics") {
//                   EditorTextField("Title", text: $draft.value.title, limit: 60, required: true)
//                   EditorEmojiField("Emoji", emoji: $draft.value.emoji)      // String?
//                   EditorDateField("Day", iso: $draft.value.day, isOptional: true)   // String? "yyyy-MM-dd"
//                   EditorTimeField("Starts", time: $draft.value.start)        // String? "HH:mm"
//               }
//           }
//       }
//   }
//
//   List editing (reorder + confirm/undo delete):
//
//       @State private var model = EditorListModel<Thing>()
//       List {
//           EditorListSection(model, header: "Things") { thing in Text(thing.title) }
//       }
//       .editorListChrome(model)               // edit button, confirm dialog, undo toast
//       .task {
//           model.persistOrder = { ids in try await service.saveOrder(ids) }
//           model.commitDelete = { thing in try await service.delete(thing) }
//           model.title = { $0.title }
//           model.replace(await service.fetch())
//       }
//
// ── RULES ────────────────────────────────────────────────────────────────────
// • Sheets: EditorSheet owns Cancel/Save, dirty guard, spinner, error banner.
//   `save` must THROW on failure (never swallow); the sheet stays open and shows
//   the message. On success it dismisses itself, so do not call dismiss() inside.
// • Text fields come in String and String? flavours (nil <-> empty).
// • Dates are ISO "yyyy-MM-dd" strings in America/Chicago (matches FestDays.isoFmt
//   and what the DB stores). Times are 24h "HH:mm" strings (legacy "2:00 PM"
//   values are still read and shown, and stay untouched until the user edits).
// • Deletes: the row leaves the list immediately, the server delete is committed
//   after a 5 second Undo window (or at once if another delete starts, or the
//   screen goes away). Chosen over "commit then re-insert" because rows with
//   server-generated ids cannot be re-inserted under their old id.

// MARK: - EditorDraft

/// Dirty tracking: the value as loaded plus the working copy. Bind fields to
/// `$draft.value.x`; `isDirty` is plain inequality.
struct EditorDraft<Value: Equatable>: Equatable {
    private(set) var original: Value
    var value: Value
    init(_ value: Value) { original = value; self.value = value }
    var isDirty: Bool { value != original }
    /// Call after a successful save if the screen stays open.
    mutating func markSaved() { original = value }
    mutating func revert() { value = original }
}

// MARK: - Error text

enum EditorError {
    /// The real message: PostgREST's server text when present, else localizedDescription.
    static func message(_ error: Error) -> String {
        if let pg = error as? PostgrestError {
            var parts = [pg.message]
            if let d = pg.detail, !d.isEmpty { parts.append(d) }
            if let h = pg.hint, !h.isEmpty { parts.append(h) }
            return parts.joined(separator: " ")
        }
        return error.localizedDescription
    }
}

// MARK: - Error banner

/// Inline red banner with an optional Retry. Used by EditorSheet; also usable on
/// pushed (non-sheet) editors.
struct EditorErrorBanner: View {
    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: MLRSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.mlrDanger)
            Text(message)
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button("Retry", action: onRetry).font(.mlrScaled(13, weight: .semibold))
            }
        }
        .padding(MLRSpacing.md)
        .background(Color.mlrDanger.opacity(0.12), in: RoundedRectangle(cornerRadius: MLRRadius.sm))
        .padding(.horizontal, MLRSpacing.page)
        .padding(.top, MLRSpacing.sm)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - EditorSheet

/// Container for any editor form. Put `Section`s in `content`.
struct EditorSheet<Content: View>: View {
    let title: String
    let isDirty: Bool
    let canSave: Bool
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDiscard = false
    @State private var didSave = false

    init(title: String, isDirty: Bool, canSave: Bool,
         save: @escaping () async throws -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.isDirty = isDirty; self.canSave = canSave
        self.save = save; self.content = content
    }

    private var guardActive: Bool { (isDirty && !didSave) || isSaving }

    var body: some View {
        NavigationStack {
            Form { content() }
                .scrollContentBackground(.hidden)
                .background(Color.mlrSurface)
                .disabled(isSaving)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let errorMessage {
                        EditorErrorBanner(message: errorMessage) { Task { await performSave() } }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: errorMessage)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { attemptCancel() }.disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await performSave() } }
                                .fontWeight(.semibold)
                                .disabled(!(isDirty && canSave))
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { EditorKeyboard.hide() }
                    }
                }
                .confirmationDialog("Discard changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                } message: {
                    Text("Your unsaved edits will be lost.")
                }
        }
        .interactiveDismissDisabled(guardActive)
        .background(EditorDismissAttemptObserver(isEnabled: isDirty && !didSave && !isSaving) {
            showDiscard = true
        })
    }

    private func attemptCancel() {
        if isDirty && !didSave { showDiscard = true } else { dismiss() }
    }

    private func performSave() async {
        guard !isSaving, isDirty, canSave else { return }   // double-tap guard
        isSaving = true
        errorMessage = nil
        EditorKeyboard.hide()
        do {
            try await save()
            didSave = true
            Haptics.success()
            isSaving = false
            dismiss()
        } catch is CancellationError {
            isSaving = false
        } catch {
            errorMessage = EditorError.message(error)
            Haptics.error()
            isSaving = false
        }
    }
}

enum EditorKeyboard {
    static func hide() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: Swipe-to-dismiss attempt hook
// SwiftUI's interactiveDismissDisabled gives no callback. This wraps the sheet's
// presentation-controller delegate (forwarding everything SwiftUI relies on) so
// an attempted swipe while dirty can raise the Discard dialog.

private struct EditorDismissAttemptObserver: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onAttempt: () -> Void

    func makeCoordinator() -> Proxy { Proxy() }
    func makeUIViewController(context: Context) -> Probe { Probe(proxy: context.coordinator) }
    func updateUIViewController(_ vc: Probe, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onAttempt = onAttempt
        vc.installIfNeeded()
    }

    final class Probe: UIViewController {
        let proxy: Proxy
        init(proxy: Proxy) { self.proxy = proxy; super.init(nibName: nil, bundle: nil); view.isHidden = true }
        required init?(coder: NSCoder) { fatalError() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); installIfNeeded() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); installIfNeeded() }
        func installIfNeeded() {
            guard let pc = parent?.presentationController ?? presentationController else { return }
            guard pc.delegate !== proxy else { return }
            proxy.forward = pc.delegate
            pc.delegate = proxy
        }
    }

    final class Proxy: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var forward: UIAdaptivePresentationControllerDelegate?
        var isEnabled = false
        var onAttempt: () -> Void = {}

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isEnabled { onAttempt() }
            forward?.presentationControllerDidAttemptToDismiss?(presentationController)
        }
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forward?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let f = forward, f.responds(to: aSelector) { return f }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

/// For pushed (non-sheet) editors: hides the back button while dirty and swaps in
/// a Back that asks "Discard changes?". Edge-swipe back is disabled with it.
private struct EditorUnsavedGuard: ViewModifier {
    let isDirty: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showDiscard = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showDiscard = true } label: {
                            Label("Back", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: { Text("Your unsaved edits will be lost.") }
    }
}

/// Leading "Done" for a pushed screen presented inside a sheet's NavigationStack.
private struct SheetDoneButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
    }
}

extension View {
    /// Adds a "Done" close button (for sheets that wrap a screen in a NavigationStack).
    func sheetDoneButton() -> some View { modifier(SheetDoneButton()) }
    /// Unsaved-changes guard for pushed editor screens (see EditorUnsavedGuard).
    func editorUnsavedGuard(isDirty: Bool) -> some View { modifier(EditorUnsavedGuard(isDirty: isDirty)) }
}

// MARK: - Field chrome

private struct EditorFieldRow<Field: View>: View {
    let label: String
    var required = false
    var counter: String?
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: MLRSpacing.xs) {
            HStack(spacing: 2) {
                Text(label)
                if required { Text("*").foregroundStyle(Color.mlrDanger) }
                Spacer()
                if let counter { Text(counter).monospacedDigit() }
            }
            .font(.mlrScaled(12, weight: .medium))
            .foregroundStyle(Color.mlrTextMuted)
            field()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Text fields

struct EditorTextField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var limit: Int?
    var required = false
    var keyboard: UIKeyboardType = .default
    var autocapitalize = true

    init(_ label: String, text: Binding<String>, placeholder: String = "", limit: Int? = nil,
         required: Bool = false, keyboard: UIKeyboardType = .default, autocapitalize: Bool = true) {
        self.label = label; _text = text; self.placeholder = placeholder; self.limit = limit
        self.required = required; self.keyboard = keyboard; self.autocapitalize = autocapitalize
    }
    /// Optional-string flavour: empty text stores nil.
    init(_ label: String, text: Binding<String?>, placeholder: String = "", limit: Int? = nil,
         required: Bool = false, keyboard: UIKeyboardType = .default, autocapitalize: Bool = true) {
        self.init(label, text: Binding(get: { text.wrappedValue ?? "" },
                                       set: { text.wrappedValue = $0.isEmpty ? nil : $0 }),
                  placeholder: placeholder, limit: limit, required: required,
                  keyboard: keyboard, autocapitalize: autocapitalize)
    }

    var body: some View {
        EditorFieldRow(label: label, required: required,
                       counter: limit.map { "\(text.count)/\($0)" }) {
            TextField(placeholder.isEmpty ? label : placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                .autocorrectionDisabled(!autocapitalize)
                .onChange(of: text) { _, new in
                    if let limit, new.count > limit { text = String(new.prefix(limit)) }
                }
        }
    }
}

/// Whole-number field (amounts). Empty stores nil.
struct EditorIntField: View {
    let label: String
    @Binding var value: Int?
    var placeholder = ""

    init(_ label: String, value: Binding<Int?>, placeholder: String = "") {
        self.label = label; _value = value; self.placeholder = placeholder
    }

    var body: some View {
        EditorFieldRow(label: label) {
            TextField(placeholder.isEmpty ? label : placeholder, value: $value, format: .number)
                .keyboardType(.numberPad)
        }
    }
}

struct EditorLongText: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var limit: Int?
    var lines: ClosedRange<Int> = 2...8

    init(_ label: String, text: Binding<String>, placeholder: String = "", limit: Int? = nil,
         lines: ClosedRange<Int> = 2...8) {
        self.label = label; _text = text; self.placeholder = placeholder; self.limit = limit; self.lines = lines
    }
    init(_ label: String, text: Binding<String?>, placeholder: String = "", limit: Int? = nil,
         lines: ClosedRange<Int> = 2...8) {
        self.init(label, text: Binding(get: { text.wrappedValue ?? "" },
                                       set: { text.wrappedValue = $0.isEmpty ? nil : $0 }),
                  placeholder: placeholder, limit: limit, lines: lines)
    }

    var body: some View {
        EditorFieldRow(label: label, counter: limit.map { "\(text.count)/\($0)" }) {
            TextField(placeholder.isEmpty ? label : placeholder, text: $text, axis: .vertical)
                .lineLimit(lines)
                .onChange(of: text) { _, new in
                    if let limit, new.count > limit { text = String(new.prefix(limit)) }
                }
        }
    }
}

struct EditorToggle: View {
    let label: String
    @Binding var isOn: Bool
    var caption: String?

    init(_ label: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.label = label; _isOn = isOn; self.caption = caption
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let caption {
                    Text(caption).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
            }
        }
        .tint(Color.mlrPrimary)
    }
}

// MARK: - Emoji

/// Small emoji picker: a curated grid plus a field for the system emoji keyboard.
/// (The app had no existing picker; committee/house editors use a bare TextField.)
struct EditorEmojiField: View {
    let label: String
    @Binding var emoji: String?
    var presets: [String] = EditorEmojiField.defaultPresets

    @State private var showPicker = false

    init(_ label: String, emoji: Binding<String?>, presets: [String] = EditorEmojiField.defaultPresets) {
        self.label = label; _emoji = emoji; self.presets = presets
    }

    static let defaultPresets = ["🍽️", "🍔", "🌮", "🍕", "🥗", "🍰", "🍦", "🥩", "🍳", "☕️", "🍺", "🍷",
                                 "🎉", "🏆", "🎯", "🎲", "🎶", "🎤", "🔥", "⛺️", "🛶", "🚤", "🎣", "🏊",
                                 "⛵️", "🌲", "🌅", "🌙", "⭐️", "🏠", "🚗", "📸", "🎁", "❤️", "👨‍👩‍👧‍👦", "🧺"]

    var body: some View {
        EditorFieldRow(label: label) {
            HStack {
                Button { showPicker = true } label: {
                    HStack(spacing: MLRSpacing.sm) {
                        Text(emoji ?? "☺︎").font(.mlrScaled(26)).opacity(emoji == nil ? 0.35 : 1)
                        Text(emoji == nil ? "Choose" : "Change").foregroundStyle(Color.mlrPrimary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if emoji != nil {
                    Button { emoji = nil; Haptics.select() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mlrTextSubtle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear emoji")
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            EmojiPickerSheet(presets: presets, emoji: $emoji)
                .presentationDetents([.medium])
        }
    }
}

private struct EmojiPickerSheet: View {
    let presets: [String]
    @Binding var emoji: String?
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MLRSpacing.lg) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: MLRSpacing.md) {
                        ForEach(presets, id: \.self) { e in
                            Button { emoji = e; Haptics.select(); dismiss() } label: {
                                Text(e).font(.mlrScaled(30))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(emoji == e ? Color.mlrPrimaryLight : .clear,
                                                in: RoundedRectangle(cornerRadius: MLRRadius.sm))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Or type any emoji", text: $typed)
                        .padding(MLRSpacing.md)
                        .background(Color.mlrGroupedCard, in: RoundedRectangle(cornerRadius: MLRRadius.sm))
                        .onChange(of: typed) { _, new in
                            // Keep the first emoji only (a grapheme cluster).
                            if let f = new.first, f.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                                emoji = String(f); Haptics.select(); dismiss()
                            } else if !new.isEmpty { typed = "" }
                        }
                }
                .padding(MLRSpacing.page)
            }
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Date / time

/// Native date picker bound to an ISO "yyyy-MM-dd" string (America/Chicago, via
/// FestDays.isoFmt). Optional + clearable when `isOptional`.
struct EditorDateField: View {
    let label: String
    @Binding var iso: String?
    var isOptional = false
    var minISO: String?

    init(_ label: String, iso: Binding<String?>, isOptional: Bool = false, minISO: String? = nil) {
        self.label = label; _iso = iso; self.isOptional = isOptional; self.minISO = minISO
    }
    init(_ label: String, iso: Binding<String>, minISO: String? = nil) {
        self.init(label, iso: Binding<String?>(get: { iso.wrappedValue }, set: { iso.wrappedValue = $0 ?? iso.wrappedValue }),
                  isOptional: false, minISO: minISO)
    }

    private static let chicago = TimeZone(identifier: "America/Chicago") ?? .current
    private var fmt: DateFormatter { FestDays.isoFmt }

    private var dateBinding: Binding<Date> {
        Binding(get: { iso.flatMap { fmt.date(from: $0) } ?? Date() },
                set: { iso = fmt.string(from: $0) })
    }

    var body: some View {
        EditorFieldRow(label: label) {
            HStack {
                if iso == nil && isOptional {
                    Button { iso = minISO ?? fmt.string(from: Date()); Haptics.select() } label: {
                        Label("Add date", systemImage: "calendar.badge.plus").foregroundStyle(Color.mlrPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                } else {
                    if let minISO, let lo = fmt.date(from: minISO) {
                        DatePicker("", selection: dateBinding, in: lo..., displayedComponents: .date)
                            .labelsHidden()
                    } else {
                        DatePicker("", selection: dateBinding, displayedComponents: .date).labelsHidden()
                    }
                    Spacer()
                    if isOptional {
                        Button { iso = nil; Haptics.select() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mlrTextSubtle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear \(label)")
                    }
                }
            }
            .environment(\.timeZone, Self.chicago)
        }
    }
}

/// Native time picker bound to a 24h "HH:mm" string, shown as 12-hour time.
/// Optional + clearable. Legacy free-text values like "2:00 PM" are read and
/// shown, and left as they are until the user changes the picker.
struct EditorTimeField: View {
    let label: String
    @Binding var time: String?
    var isOptional = true

    init(_ label: String, time: Binding<String?>, isOptional: Bool = true) {
        self.label = label; _time = time; self.isOptional = isOptional
    }

    /// "HH:mm" (or legacy "h:mm AM/PM") -> (hour, minute); nil if unparseable.
    static func parts(_ s: String?) -> (h: Int, m: Int)? {
        guard var str = s?.trimmingCharacters(in: .whitespaces).uppercased(), !str.isEmpty else { return nil }
        var isPM: Bool?
        if str.hasSuffix("AM") { isPM = false; str.removeLast(2) }
        else if str.hasSuffix("PM") { isPM = true; str.removeLast(2) }
        let p = str.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count >= 2, let h0 = Int(p[0]), let m = Int(p[1]), (0...59).contains(m) else { return nil }
        if let isPM {
            guard (1...12).contains(h0) else { return nil }
            return (h0 == 12 ? (isPM ? 12 : 0) : (isPM ? h0 + 12 : h0), m)
        }
        guard (0...23).contains(h0) else { return nil }
        return (h0, m)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                let p = Self.parts(time) ?? (12, 0)
                return Calendar.current.date(bySettingHour: p.h, minute: p.m, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }

    var body: some View {
        EditorFieldRow(label: label) {
            HStack {
                if Self.parts(time) == nil && time?.isEmpty != false && isOptional {
                    Button { time = "12:00"; Haptics.select() } label: {
                        Label("Add time", systemImage: "clock.badge.plus").foregroundStyle(Color.mlrPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                } else {
                    DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "en_US"))   // 12-hour display
                    Spacer()
                    if isOptional {
                        Button { time = nil; Haptics.select() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.mlrTextSubtle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear \(label)")
                    }
                }
            }
        }
    }
}

// MARK: - Links

struct EditorLink: Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var url = ""

    /// http(s) with a host.
    static func isValidURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host, host.contains(".") else { return false }
        return true
    }
    /// Use in `canSave`: every row has a valid URL (drop blank rows before saving).
    static func allValid(_ links: [EditorLink]) -> Bool {
        links.allSatisfy { $0.url.trimmingCharacters(in: .whitespaces).isEmpty ? false : isValidURL($0.url) }
    }
}

/// Ordered label + URL list with add / remove / move up-down and URL validation.
struct EditorLinksField: View {
    let label: String
    @Binding var links: [EditorLink]
    var maxCount = 6

    init(_ label: String = "Links", links: Binding<[EditorLink]>, maxCount: Int = 6) {
        self.label = label; _links = links; self.maxCount = maxCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MLRSpacing.sm) {
            Text(label).font(.mlrScaled(12, weight: .medium)).foregroundStyle(Color.mlrTextMuted)
            ForEach($links) { $link in
                let index = links.firstIndex(where: { $0.id == link.id }) ?? 0
                VStack(alignment: .leading, spacing: MLRSpacing.xs) {
                    HStack {
                        TextField("Label (e.g. Menu)", text: $link.label)
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index >= links.count - 1)
                        Button(role: .destructive) {
                            withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { links.removeAll { $0.id == link.id } }
                            Haptics.tap()
                        } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    TextField("https://…", text: $link.url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !link.url.isEmpty && !EditorLink.isValidURL(link.url) {
                        Text("Enter a full web address starting with http:// or https://")
                            .font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    }
                }
                .padding(.vertical, 2)
                Divider()
            }
            if links.count < maxCount {
                Button {
                    withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { links.append(EditorLink()) }
                    Haptics.tap()
                } label: { Label("Add a link", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard links.indices.contains(i), links.indices.contains(j) else { return }
        withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { links.swapAt(i, j) }
        Haptics.select()
    }
}

// MARK: - Image

/// Shows the current image; pick (PhotosPicker), replace or remove. Uploading
/// happens immediately via `upload`, which returns the public URL; callers choose
/// the destination, e.g. `{ img in try await env.mediaService.uploadSiteImage(image: img, key: "x") }`.
/// The URL binding changes only on success, so the sheet's dirty tracking and
/// Save handle persistence.
struct EditorImageField: View {
    let label: String
    @Binding var url: String?
    let upload: (UIImage) async throws -> String

    @State private var pick: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?

    init(_ label: String, url: Binding<String?>, upload: @escaping (UIImage) async throws -> String) {
        self.label = label; _url = url; self.upload = upload
    }

    var body: some View {
        EditorFieldRow(label: label) {
            VStack(alignment: .leading, spacing: MLRSpacing.sm) {
                if let s = url, let u = URL(string: s) {
                    KFImage(u).resizable().scaledToFit()
                        .frame(maxHeight: 160).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: MLRRadius.sm))
                        .overlay { if uploading { Color.black.opacity(0.35); ProgressView().tint(.white) } }
                }
                HStack {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(url == nil ? "Choose photo" : "Replace photo", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(uploading)
                    Spacer()
                    if url != nil {
                        Button("Remove", role: .destructive) { url = nil; error = nil; Haptics.tap() }
                            .disabled(uploading)
                    }
                }
                .buttonStyle(.borderless)
                if uploading && url == nil {
                    HStack(spacing: 8) { ProgressView(); Text("Uploading…").font(.mlrCaption).foregroundStyle(Color.mlrTextMuted) }
                }
                if let error { Text(error).font(.mlrCaption).foregroundStyle(Color.mlrDanger) }
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task { await run(item) }
        }
    }

    private func run(_ item: PhotosPickerItem) async {
        uploading = true; error = nil
        defer { uploading = false; pick = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                error = "Couldn't read that image."; Haptics.error(); return
            }
            url = try await upload(img)
            Haptics.success()
        } catch {
            self.error = "Upload failed. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}

// MARK: - Colour

/// ColorPicker bound to an optional "#RRGGBB" string. nil = "Default".
struct EditorColorField: View {
    let label: String
    @Binding var hex: String?
    var presets: [String] = ["#15503A", "#C2410C", "#1D6A8C", "#E0A416", "#4338CA", "#6B0F24", "#C29A2E", "#16A34A"]
    var defaultColor: Color = .mlrPrimary

    init(_ label: String, hex: Binding<String?>, presets: [String]? = nil, defaultColor: Color = .mlrPrimary) {
        self.label = label; _hex = hex; self.defaultColor = defaultColor
        if let presets { self.presets = presets }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { hex.map { Color(hex: $0) } ?? defaultColor },
                set: { hex = Self.hexString($0) })
    }

    static func hexString(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var body: some View {
        EditorFieldRow(label: label) {
            VStack(alignment: .leading, spacing: MLRSpacing.sm) {
                HStack {
                    ColorPicker(hex ?? "Default \u{00B7} \(Self.hexString(defaultColor))", selection: colorBinding, supportsOpacity: false)
                    if hex != nil {
                        Button("Default") { hex = nil; Haptics.select() }.buttonStyle(.borderless)
                    }
                }
                HStack(spacing: MLRSpacing.sm) {
                    ForEach(presets, id: \.self) { p in
                        Button { hex = p; Haptics.select() } label: {
                            Circle().fill(Color(hex: p)).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Color.mlrBorder, lineWidth: 1))
                                .overlay { if hex?.uppercased() == p.uppercased() {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(p)")
                    }
                }
            }
        }
    }
}

// MARK: - Reorderable list

/// Backing model for a list of editable rows: optimistic reorder (rolls back and
/// shows an error toast if `persistOrder` throws) and delayed-commit delete with
/// an Undo window. Create with `@State private var model = EditorListModel<Row>()`,
/// set the closures in `.task`, and `replace(_:)` whenever you reload from the server.
@MainActor @Observable
final class EditorListModel<Item: Identifiable> {
    var items: [Item] = []
    /// Persist the new full order (write real `position` values). Throw on failure.
    @ObservationIgnored var persistOrder: ([Item.ID]) async throws -> Void = { _ in }
    /// Perform the real server delete. Called after the Undo window.
    @ObservationIgnored var commitDelete: (Item) async throws -> Void = { _ in }
    @ObservationIgnored var title: (Item) -> String = { _ in "item" }
    @ObservationIgnored var undoSeconds: Double = 5

    var pendingConfirm: Item?
    private(set) var undoTitle: String?
    private(set) var errorMessage: String?

    private var pendingDelete: (item: Item, index: Int)?
    private var commitTask: Task<Void, Never>?
    private var orderTask: Task<Void, Never>?

    /// Swap in fresh server data, keeping a pending (uncommitted) delete hidden.
    func replace(_ new: [Item]) {
        if let p = pendingDelete { items = new.filter { $0.id != p.item.id } } else { items = new }
    }

    func move(group: (Item) -> Bool, from: IndexSet, to: Int) {
        let before = items
        let slots = items.indices.filter { group(items[$0]) }
        var visible = slots.map { items[$0] }
        visible.move(fromOffsets: from, toOffset: to)
        for (slot, item) in zip(slots, visible) { items[slot] = item }
        let ids = items.map(\.id)
        Haptics.select()
        let previous = orderTask
        orderTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await self.persistOrder(ids) }
            catch {
                self.items = before
                self.show(error: EditorError.message(error))
            }
        }
    }

    func confirmDelete() {
        guard let item = pendingConfirm else { return }
        pendingConfirm = nil
        flushPendingDelete()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        pendingDelete = (item, index)
        undoTitle = title(item)
        Haptics.warning()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.undoSeconds ?? 5))
            guard !Task.isCancelled else { return }
            await self?.commit()
        }
    }

    func undo() {
        commitTask?.cancel(); commitTask = nil
        guard let p = pendingDelete else { return }
        items.insert(p.item, at: min(p.index, items.count))
        pendingDelete = nil; undoTitle = nil
        Haptics.select()
    }

    /// Commit a waiting delete now (new delete started, or the screen disappeared).
    func flushPendingDelete() {
        guard pendingDelete != nil else { return }
        commitTask?.cancel(); commitTask = nil
        Task { await commit() }
    }

    private func commit() async {
        guard let p = pendingDelete else { return }
        pendingDelete = nil; undoTitle = nil
        do { try await commitDelete(p.item) }
        catch {
            items.insert(p.item, at: min(p.index, items.count))
            show(error: "Couldn\u{2019}t delete \u{201C}\(title(p.item))\u{201D}. \(EditorError.message(error))")
        }
    }

    private func show(error: String) {
        errorMessage = error
        Haptics.error()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.errorMessage == error { self?.errorMessage = nil }
        }
    }
}

/// A `Section` of rows with drag-to-reorder and swipe-to-delete (confirm + undo).
/// `group` limits the section to a subset (e.g. one day); reordering then only
/// permutes those rows within the full list, so cross-group order stays valid.
/// Pair with `.editorListChrome(model)` on the enclosing List.
struct EditorListSection<Item: Identifiable, Row: View>: View {
    let model: EditorListModel<Item>
    var header: String?
    var group: (Item) -> Bool
    @ViewBuilder let row: (Item) -> Row

    init(_ model: EditorListModel<Item>, header: String? = nil,
         group: @escaping (Item) -> Bool = { _ in true },
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.model = model; self.header = header; self.group = group; self.row = row
    }

    var body: some View {
        let visible = model.items.filter(group)
        Section {
            ForEach(visible) { item in row(item) }
                .onMove { from, to in model.move(group: group, from: from, to: to) }
                .onDelete { idx in
                    if let i = idx.first, visible.indices.contains(i) { model.pendingConfirm = visible[i] }
                }
        } header: {
            if let header { Text(header) }
        }
    }
}

private struct EditorListChrome<Item: Identifiable>: ViewModifier {
    @Bindable var model: EditorListModel<Item>
    let editButton: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .toolbar { if editButton { ToolbarItem(placement: .topBarTrailing) { EditButton() } } }
            .confirmationDialog(
                model.pendingConfirm.map { "Delete \u{201C}\(model.title($0))\u{201D}?" } ?? "Delete?",
                isPresented: Binding(get: { model.pendingConfirm != nil },
                                     set: { if !$0 { model.pendingConfirm = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { model.confirmDelete() }
                Button("Cancel", role: .cancel) { model.pendingConfirm = nil }
            }
            .overlay(alignment: .bottom) {
                if let t = model.undoTitle {
                    toast {
                        Text("Deleted \u{201C}\(t)\u{201D}").lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Undo") { model.undo() }.fontWeight(.semibold)
                    }
                } else if let e = model.errorMessage {
                    toast { Image(systemName: "exclamationmark.triangle.fill"); Text(e).lineLimit(3) }
                }
            }
            .animation(reduceMotion ? nil : MLRMotion.spring, value: model.undoTitle)
            .animation(reduceMotion ? nil : MLRMotion.spring, value: model.errorMessage)
            .onDisappear { model.flushPendingDelete() }
    }

    private func toast<T: View>(@ViewBuilder _ inner: () -> T) -> some View {
        HStack(spacing: MLRSpacing.sm) { inner() }
            .font(.mlrScaled(14))
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, MLRSpacing.lg).padding(.vertical, MLRSpacing.md)
            .background(Color.black.opacity(0.85), in: Capsule())
            .padding(.horizontal, MLRSpacing.page).padding(.bottom, MLRSpacing.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Edit button, delete confirmation dialog, Undo / error toast for `EditorListSection`s.
    /// With several models on one List, pass `editButton: false` on all but one.
    func editorListChrome<Item: Identifiable>(_ model: EditorListModel<Item>, editButton: Bool = true) -> some View {
        modifier(EditorListChrome(model: model, editButton: editButton))
    }
}

// MARK: - EditPencil
// The one "edit this, right here" control. Someone with edit rights sees it on
// the real screen next to the thing itself; it opens the editor for exactly
// that thing. Callers decide who sees it and must hide it while an admin is
// previewing as another member.

struct EditPencil: View {
    /// What is being edited, for VoiceOver ("Edit <thing>").
    let thing: String
    var tint: Color = .mlrPrimary
    /// Over a photo or a dark hero: white disc, tinted glyph, soft shadow.
    var onDark = false
    let action: () -> Void

    init(_ thing: String, tint: Color = .mlrPrimary, onDark: Bool = false, action: @escaping () -> Void) {
        self.thing = thing
        self.tint = tint
        self.onDark = onDark
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "pencil.circle.fill")
                .font(.mlrScaled(24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(onDark ? tint : Color.white, onDark ? Color.white : tint)
                .shadow(color: .black.opacity(onDark ? 0.25 : 0), radius: 2, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Edit \(thing)")
    }
}
