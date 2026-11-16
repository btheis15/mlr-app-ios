import SwiftUI

// MARK: - Start next year's fest
//
// The whole archive/start-fresh cycle lives in data: adding a `fest_config` row
// slides the finished fest into Past Years and points the hub at the new season.
// No deploy, no schema change, nothing to archive by hand.
//
// ⚠️ This INSERTS a new row. It never edits the current one. Moving the live
// row's dates drags the finished fest forward with them — so its archive would
// describe a week that never happened, and the app would count down to it all
// over again.

/// Pushed from the Planner, which can't be edited here. EditorSheet owns its own
/// NavigationStack, so this just presents the sheet at once and pops itself when
/// it closes. (Once the Planner presents the sheet directly, this can go.)
private struct SheetLaunchPad<Sheet: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showing = false
    @State private var launched = false
    @ViewBuilder let sheet: () -> Sheet

    var body: some View {
        Color.clear
            .onAppear {
                guard !launched else { return }
                launched = true
                showing = true
            }
            .sheet(isPresented: $showing, onDismiss: { dismiss() }) { sheet() }
    }
}

struct StartNextFestYearView: View {
    var body: some View { SheetLaunchPad { StartNextFestYearSheet() } }
}

struct StartNextFestYearSheet: View {
    @Environment(AppEnvironment.self) private var env

    // ⚠️ Both dates start EMPTY (nil) and are picked by hand. The fest week is
    // different every year and the family decides it by poll, so there is
    // nothing correct to default to — the web shipped a "+52 weeks" default and
    // it was wrong. nil keeps "not yet chosen" distinguishable from "today".
    struct Values: Equatable {
        var name = ""
        var tagline = ""
        var startISO: String?
        var endISO: String?
        var copyFrom: Int?
    }

    @State private var draft = EditorDraft(Values())

    private var service: FestContentService { env.festContentService }

    /// Derived from the START DATE, never typed separately, so the two can't
    /// disagree — a row labelled 2027 whose week is in 2028 would file itself
    /// under the wrong year forever.
    private var derivedYear: Int? {
        draft.value.startISO.flatMap { Int($0.prefix(4)) }
    }

    private var endBeforeStart: Bool {
        guard let s = draft.value.startISO, let e = draft.value.endISO else { return false }
        return e < s   // ISO yyyy-MM-dd compares chronologically
    }

    private var canSave: Bool {
        let v = draft.value
        return !v.name.trimmingCharacters(in: .whitespaces).isEmpty
            && v.startISO != nil && v.endISO != nil && !endBeforeStart
    }

    var body: some View {
        EditorSheet(title: "Start next year", isDirty: draft.isDirty, canSave: canSave,
                    save: { try await create() }) {
            Section {
                EditorTextField("Name", text: $draft.value.name, required: true)
                EditorTextField("Tagline (optional)", text: $draft.value.tagline)
            } header: {
                Text(derivedYear.map { "Family Fest \(String($0))" } ?? "The new fest")
            } footer: {
                Text("The year comes from the start date. Leave the theme for later — a new fest starts with the classic look, and picking its own is part of planning it.")
            }

            Section {
                EditorDateField("Starts", iso: $draft.value.startISO, isOptional: true)
                EditorDateField("Ends", iso: $draft.value.endISO, isOptional: true)
                if endBeforeStart {
                    Label("The end date is before the start.", systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(12))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("The week")
            } footer: {
                Text("Nothing is guessed here — the fest week moves every year, so both dates are picked by hand.")
            }

            if !service.allYears.isEmpty {
                Section {
                    Picker("Copy the plan from", selection: $draft.value.copyFrom) {
                        Text("Start empty").tag(Int?.none)
                        ForEach(service.allYears) { y in
                            Text(String(y.year)).tag(Int?.some(y.year))
                        }
                    }
                } footer: {
                    Text("Copies the schedule, dinners, dues and payees forward, shifting each day by however far the new week moved. You can edit everything afterwards.")
                }
            }
        }
        .task { await service.load() }
    }

    private func create() async throws {
        let v = draft.value
        guard let start = v.startISO, let end = v.endISO else { return }
        let tagline = v.tagline.trimmingCharacters(in: .whitespaces)
        let out = try await service.startFestYear(
            name: v.name.trimmingCharacters(in: .whitespaces),
            tagline: tagline.isEmpty ? nil : tagline,
            startDate: start, endDate: end,
            copyFromYear: v.copyFrom)
        // ⚠️ A partial copy reports itself. The year EXISTS either way, so the
        // draft is marked saved (Save disables, Cancel won't ask to discard) and
        // the warning is thrown so the sheet stays open and shows it.
        if let warning = out.warning {
            draft.markSaved()
            throw FestYearError.message(warning)
        }
    }
}

// MARK: - This year's theme & cover (migration 0219)

/// Presets matching web's `FEST_PRESETS` (lib/festTheme.ts). nil = built-in.
private struct FestLookPreset: Identifiable {
    let id: String
    let name: String
    let look: FestTheme
}

private let festLookPresets: [FestLookPreset] = [
    .init(id: "parchment", name: "Parchment & Heraldry",
          look: FestTheme(bgStyle: "default", font: "cinzel")),
    .init(id: "northwoods", name: "Northwoods Pine",
          look: FestTheme(primary: "#15503a", accent: "#c2410c", background: "#f4f1e8", card: "#ffffff",
                          border: "#ddd6c4", ink: "#26301f", bgStyle: "default", font: "sans")),
    .init(id: "lakeside", name: "Lakeside Summer",
          look: FestTheme(primary: "#0f6d80", accent: "#b45309", background: "#eef7f8", card: "#ffffff",
                          border: "#c9dfe3", ink: "#173038", bgStyle: "default", font: "playfair")),
    .init(id: "campfire", name: "Campfire Dusk",
          look: FestTheme(primary: "#5b2a86", accent: "#c2410c", background: "#f6f1fa", card: "#ffffff",
                          border: "#ddd0e8", ink: "#2b1f38", bgStyle: "default", font: "playfair")),
    .init(id: "carnival", name: "Carnival Stripes",
          look: FestTheme(primary: "#b91c1c", accent: "#0f766e", background: "#fff8ec", card: "#ffffff",
                          border: "#f0dcbb", ink: "#3b2415", bgStyle: "default", font: "cinzel")),
]

/// Pushed from the Planner (see SheetLaunchPad). Edit-in-place on the overview
/// presents `FestYearLookSheet` directly.
struct FestYearLookEditor: View {
    var body: some View { SheetLaunchPad { FestYearLookSheet() } }
}

/// Every column is nullable and null means "use the built-in look", so clearing
/// a field here is a real answer, not an empty form. One Save writes the whole
/// look in a single upsert.
struct FestYearLookSheet: View {
    @Environment(AppEnvironment.self) private var env

    struct Values: Equatable {
        var theme: String?
        var coverUrl: String?
        var look: FestTheme = .builtIn
    }

    @State private var draft = EditorDraft(Values())
    @State private var loaded = false
    @State private var confirmReset = false

    private var service: FestContentService { env.festContentService }

    private func slot(_ title: String, _ s: FestTheme.Slot, _ kp: WritableKeyPath<FestTheme, String?>) -> some View {
        EditorColorField(title,
                         hex: Binding(get: { draft.value.look[keyPath: kp] },
                                      set: { draft.value.look[keyPath: kp] = $0 }),
                         presets: [],
                         defaultColor: Color(hex: FestTheme.defaults[s]!))
    }

    private func applyPreset(_ p: FestLookPreset) {
        var next = p.look
        // Keep an uploaded backdrop so switching preset never discards it.
        next.bgImageUrl = draft.value.look.bgImageUrl
        next.bgImageMode = draft.value.look.bgImageMode
        next.bgImageOpacity = draft.value.look.bgImageOpacity
        draft.value.look = next
        Haptics.select()
    }

    private func upload(_ image: UIImage) async throws -> String {
        try await env.mediaService.uploadSiteImage(image: image, key: "fest/\(service.year)")
    }

    var body: some View {
        EditorSheet(title: "Theme & cover", isDirty: draft.isDirty, canSave: loaded,
                    save: {
            let v = draft.value
            let t = v.theme?.trimmingCharacters(in: .whitespaces) ?? ""
            let c = v.coverUrl?.trimmingCharacters(in: .whitespaces) ?? ""
            try await service.saveYearLook(theme: t.isEmpty ? nil : t,
                                           coverUrl: c.isEmpty ? nil : c,
                                           look: v.look)
        }) {
            // Live preview: drawn from the draft, never written, and it never
            // touches FestThemeStore.active.
            Section {
                FestLookPreview(look: draft.value.look, coverUrl: draft.value.coverUrl,
                                themeLine: draft.value.theme)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Preview")
            }

            Section {
                EditorTextField("Theme", text: $draft.value.theme, placeholder: "e.g. Ye Olde Family Feste")
            } header: {
                Text("This year's theme")
            } footer: {
                Text("The line people remember the year by. Leave it empty for no theme.")
            }

            Section {
                EditorImageField("Cover photo", url: $draft.value.coverUrl, upload: upload)
            } footer: {
                Text("This year's own cover, kept with the year — so next year's poster never replaces the one the archive shows. Removing it falls back to the classic art.")
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MLRSpacing.sm) {
                        ForEach(festLookPresets) { p in
                            Button { applyPreset(p) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(hex: p.look.primary ?? FestTheme.defaults[.primary]!))
                                        .frame(width: 14, height: 14)
                                    Circle().fill(Color(hex: p.look.accent ?? FestTheme.defaults[.accent]!))
                                        .frame(width: 14, height: 14)
                                    Text(p.name).font(.mlrScaled(13, weight: .medium))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.mlrPrimary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("One tap sets a matching palette and font; tune any colour afterwards.")
            }

            Section {
                slot("Main colour", .primary, \.primary)
                slot("Accent", .accent, \.accent)
                slot("Background", .background, \.background)
                slot("Cards", .card, \.card)
                slot("Borders", .border, \.border)
                slot("Text", .ink, \.ink)
                ForEach(draft.value.look.contrastWarnings(), id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(12))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Colours")
            } footer: {
                Text("Light mode only; dark mode keeps the app's fest palette and uses just the main colour and accent. Colours left on Default keep the built-in look.")
            }

            Section {
                Picker("Background", selection: Binding(
                    get: { draft.value.look.bgStyle ?? "default" },
                    set: { draft.value.look.bgStyle = $0 })) {
                    Text("Default").tag("default")
                    Text("Flat").tag("flat")
                    Text("Image").tag("image")
                }
                if draft.value.look.bgStyle == "image" {
                    EditorImageField("Background image", url: $draft.value.look.bgImageUrl, upload: upload)
                    Picker("Image", selection: Binding(
                        get: { draft.value.look.bgImageMode ?? "cover" },
                        set: { draft.value.look.bgImageMode = $0 })) {
                        Text("Cover").tag("cover")
                        Text("Tile").tag("tile")
                    }
                    VStack(alignment: .leading) {
                        Text("Image strength \(draft.value.look.bgImageOpacity ?? 35)%")
                            .font(.mlrScaled(13))
                        Slider(value: Binding(
                            get: { Double(draft.value.look.bgImageOpacity ?? 35) },
                            set: { draft.value.look.bgImageOpacity = Int($0.rounded()) }),
                               in: 0...100, step: 5)
                    }
                }
                Picker("Heading font", selection: Binding(
                    get: { draft.value.look.font ?? "cinzel" },
                    set: { draft.value.look.font = $0 })) {
                    Text("Cinzel").tag("cinzel")
                    Text("Serif (Playfair)").tag("playfair")
                    Text("Sans").tag("sans")
                }
            } header: {
                Text("Background & font")
            }

            Section {
                Button("Reset to built-in", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset this year's colours, background and font to the built-in look?",
                                        isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset to built-in", role: .destructive) {
                            draft.value.look = .builtIn
                            Haptics.tap()
                        }
                    } message: {
                        Text("Tap Save to apply.")
                    }
            }
        }
        .task {
            await service.load()
            guard !loaded else { return }
            let cfg = service.config
            draft = EditorDraft(Values(theme: cfg?.theme, coverUrl: cfg?.coverUrl, look: cfg?.look ?? .builtIn))
            loaded = true
        }
    }
}
