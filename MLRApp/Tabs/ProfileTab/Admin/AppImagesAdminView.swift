import SwiftUI
import PhotosUI

// MARK: - AppImagesAdminView
//
// Admin/committee screen to swap key site images (the Home logo, the Family Fest
// cover, …) without shipping a new build. Uploads to the public `site-assets`
// bucket and saves the URL in `app_images` (migration 0054); both web + iOS read
// it and fall back to the bundled asset. "Reset" clears the URL → back to the
// bundled default.

struct AppImagesAdminView: View {
    @Environment(AppEnvironment.self) private var env

    struct ManagedImage: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let fallback: String
        let note: String
        /// Wide banner (cover) vs compact (logo) — just a preview-height hint.
        let wide: Bool
    }

    private let images: [ManagedImage] = [
        .init(key: SiteImageKey.homeLogo, title: "Home logo", fallback: "brand-logo-green",
              note: "Shown at the top of the Home screen.", wide: false),
        .init(key: SiteImageKey.festCover, title: "Family Fest cover", fallback: "family-fest-cover",
              note: "The banner across the Family Fest tab.", wide: true),
    ]

    var body: some View {
        List {
            Section {
                Text("Pick a new image to replace the default everywhere — web and iOS update together. Reset to go back to the built-in art.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(images) { img in
                Section(img.title) {
                    AppImageRow(key: img.key, fallback: img.fallback, note: img.note, wide: img.wide)
                }
            }
        }
        .navigationTitle("App Images")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.appImagesService.load() }
    }
}

// MARK: - Row

private struct AppImageRow: View {
    @Environment(AppEnvironment.self) private var env
    let key: String
    let fallback: String
    let note: String
    let wide: Bool

    @State private var item: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?

    private var hasCustom: Bool { env.appImagesService.url(for: key) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SiteImage(key: key, fallback: fallback)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: wide ? 170 : 110)
                .padding(.vertical, 4)

            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                PhotosPicker(selection: $item, matching: .images) {
                    Label(hasCustom ? "Replace photo" : "Change photo", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(uploading)
                Spacer()
                if hasCustom {
                    Button(role: .destructive) {
                        Task { await reset() }
                    } label: {
                        Text("Reset")
                    }
                    .disabled(uploading)
                }
            }

            if uploading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.mlrDanger)
            }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { await upload(newItem) }
        }
    }

    private func upload(_ pick: PhotosPickerItem) async {
        uploading = true
        error = nil
        defer { uploading = false; item = nil }
        do {
            guard let data = try await pick.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                error = "Couldn't read that image."
                return
            }
            let url = try await env.mediaService.uploadSiteImage(image: uiImage, key: key)
            try await env.appImagesService.save(key: key, url: url)
        } catch {
            self.error = "Upload failed. \(EditorError.message(error))"
            Haptics.error()
        }
    }

    private func reset() async {
        error = nil
        do {
            try await env.appImagesService.reset(key: key)
        } catch {
            self.error = "Couldn\u{2019}t reset to default. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}

// MARK: - In-place pencil on the Home logo

/// Puts a small pencil on the Home logo for whoever may edit app images
/// (admins, plus fest editors via `can_edit_fest`, the same rule
/// `AppImagesService.canEdit()` documents). Hidden while previewing as someone
/// else. Opens the App Images screen as a sheet.
private struct HomeLogoEditPencil: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var canEdit = false
    @State private var open = false

    func body(content: Content) -> some View {
        content
            // Bottom-trailing: the leading edge holds the admin date preview and
            // the trailing centre holds Search.
            .overlay(alignment: .bottomTrailing) {
                if (env.isAdmin || canEdit) && !env.isPreviewing {
                    EditPencil("app images") { open = true }
                        .padding(.trailing, 8)
                }
            }
            // A sheet, not a navigationDestination: this sits inside Home's lazy stack.
            .sheet(isPresented: $open) {
                NavigationStack { AppImagesAdminView().sheetDoneButton() }
            }
            .task(id: env.currentProfile?.id) {
                guard env.isSignedIn, !env.isAdmin else { return }
                canEdit = await env.appImagesService.canEdit()
            }
    }
}

extension View {
    /// See `HomeLogoEditPencil`.
    func homeLogoEditPencil() -> some View { modifier(HomeLogoEditPencil()) }
}


// MARK: - AdminLogoFXView
//
// Admin editor for the Home logo's seasonal effects: a master switch plus, per
// season, an on/off and month/day start and end. Stored in the `resort_config`
// singleton's `logo_fx` jsonb column (migration 0229); null = built-in defaults.
// Reads are public, writes are admin-only under RLS.

struct AdminLogoFXView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    struct SeasonValues: Equatable {
        var on = true
        var start = MonthDay(1, 1)
        var end = MonthDay(1, 1)
    }
    struct Values: Equatable {
        var master = true
        var seasons: [Season: SeasonValues] = [:]

        init(_ s: LogoFXSchedule) {
            master = s.masterOn
            for k in Season.allCases { seasons[k] = SeasonValues(on: s.isOn(k), start: s.start(k), end: s.end(k)) }
        }
        var schedule: LogoFXSchedule {
            var out = LogoFXSchedule()
            out.enabled = master
            for k in Season.allCases {
                let v = seasons[k]!
                out.seasons[k.configKey] = .init(enabled: v.on, start: v.start.string, end: v.end.string)
            }
            return out
        }
    }

    @State private var draft = EditorDraft(Values(LogoFXSchedule()))
    @State private var seeded = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmReset = false
    @State private var preview: Season = .fall

    private let order: [Season] = [.fall, .winter, .spring, .summer]

    var body: some View {
        Form {
            Section {
                Toggle("Seasonal effects", isOn: $draft.value.master)
            } footer: {
                Text("Off shows the plain Home logo all year.")
            }
            if draft.value.master {
                ForEach(order, id: \.self) { s in seasonSection(s) }
                let warnings = draft.value.schedule.overlapWarnings()
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Color.mlrWarning)
                        }
                    }
                }
            }
            Section("Preview") {
                Picker("Season", selection: $preview) {
                    ForEach(order, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HomeLogoImage(season: preview, dark: colorScheme == .dark, width: 104)
                    .id(preview)
                    .frame(maxWidth: .infinity, minHeight: 130)
            }
            Section {
                Button("Reset to defaults", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Defaults: winter Dec 1 \u{2013} Feb 28, spring Mar 1 \u{2013} May 31, summer Jun 1 \u{2013} Aug 31, autumn Sep 1 \u{2013} Nov 30.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage { EditorErrorBanner(message: errorMessage) { Task { await save() } } }
        }
        .navigationTitle("Logo effects")
        .navigationBarTitleDisplayMode(.large)
        .editorUnsavedGuard(isDirty: draft.isDirty)
        .confirmationDialog("Reset logo effects to the built-in schedule?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset to defaults", role: .destructive) { Task { await reset() } }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold).disabled(!draft.isDirty)
                }
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draft = EditorDraft(Values(LogoFXStore.shared.schedule))
        }
    }

    @ViewBuilder
    private func seasonSection(_ s: Season) -> some View {
        let v = draft.value.seasons[s]!
        Section {
            Toggle(s.title, isOn: Binding(get: { draft.value.seasons[s]!.on }, set: { draft.value.seasons[s]!.on = $0 }))
            if v.on {
                dayPicker("Start", Binding(get: { draft.value.seasons[s]!.start }, set: { draft.value.seasons[s]!.start = $0 }))
                dayPicker("End", Binding(get: { draft.value.seasons[s]!.end }, set: { draft.value.seasons[s]!.end = $0 }))
            }
        } footer: {
            Text(v.on ? "\(v.start.words) \u{2013} \(v.end.words)" : "Off")
        }
    }

    private func dayPicker(_ title: String, _ b: Binding<MonthDay>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("Month", selection: Binding(get: { b.wrappedValue.month }, set: {
                b.wrappedValue = MonthDay($0, min(b.wrappedValue.day, MonthDay.monthDays[$0 - 1]))
            })) {
                ForEach(1...12, id: \.self) { Text(MonthDay.monthNames[$0 - 1]).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
            Picker("Day", selection: Binding(get: { b.wrappedValue.day }, set: {
                b.wrappedValue = MonthDay(b.wrappedValue.month, $0)
            })) {
                ForEach(1...MonthDay.monthDays[b.wrappedValue.month - 1], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
        }
    }

    private func write(_ value: AnyJSON, then done: @MainActor () -> Void) async {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            // Only logo_fx is sent; the other resort_config columns are untouched.
            try await supabase.from("resort_config")
                .upsert(["logo_fx": value], onConflict: "id")
                .execute()
            done()
            Haptics.success()
        } catch {
            errorMessage = "Couldn\u{2019}t save. \(EditorError.message(error))"
            Haptics.error()
        }
    }

    private func save() async {
        guard draft.isDirty else { return }
        let sched = draft.value.schedule
        guard let data = try? JSONSerialization.data(withJSONObject: sched.json),
              let json = try? JSONDecoder().decode(AnyJSON.self, from: data) else { return }
        await write(json) {
            LogoFXStore.shared.set(sched)
            draft.markSaved()
        }
    }

    private func reset() async {
        await write(.null) {
            LogoFXStore.shared.set(nil)
            draft = EditorDraft(Values(LogoFXSchedule()))
        }
    }
}
