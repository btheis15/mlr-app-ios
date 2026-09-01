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

struct StartNextFestYearView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var tagline = ""
    // ⚠️ Both dates start EMPTY and are typed in by hand. The fest week is
    // different every year and the family decides it by poll, so there is
    // nothing correct to default to — the web shipped a "+52 weeks" default and
    // it was wrong. `hasStart`/`hasEnd` keep "not yet chosen" distinguishable
    // from "happens to be today", which a bare `Date` cannot express.
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var copyFrom: Int?
    @State private var saving = false
    @State private var error: String?
    @State private var result: String?

    private var service: FestContentService { env.festContentService }

    /// Derived from the START DATE, never typed separately, so the two can't
    /// disagree — a row labelled 2027 whose week is in 2028 would file itself
    /// under the wrong year forever.
    private var derivedYear: Int? {
        hasStart ? Calendar.current.component(.year, from: startDate) : nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && hasStart && hasEnd && endDate >= startDate && !saving
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Tagline (optional)", text: $tagline)
            } header: {
                Text(derivedYear.map { "Family Fest \(String($0))" } ?? "The new fest")
            } footer: {
                Text("The year comes from the start date. Leave the theme for later — a new fest starts with the classic look, and picking its own is part of planning it.")
            }

            Section {
                Toggle("Start date chosen", isOn: $hasStart.animation())
                if hasStart {
                    DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                }
                Toggle("End date chosen", isOn: $hasEnd.animation())
                if hasEnd {
                    DatePicker("Ends", selection: $endDate, displayedComponents: .date)
                }
                if hasStart, hasEnd, endDate < startDate {
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
                    Picker("Copy the plan from", selection: $copyFrom) {
                        Text("Start empty").tag(Int?.none)
                        ForEach(service.allYears) { y in
                            Text(String(y.year)).tag(Int?.some(y.year))
                        }
                    }
                } footer: {
                    Text("Copies the schedule, dinners, dues and payees forward, shifting each day by however far the new week moved. You can edit everything afterwards.")
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
            if let result {
                Section {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrSuccess)
                }
            }
        }
        .navigationTitle("Start next year")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Create").fontWeight(.semibold) }
                }
                .disabled(!canSave)
            }
        }
        .task { await service.load() }
    }

    private func save() async {
        saving = true
        error = nil
        result = nil
        defer { saving = false }

        do {
            let out = try await service.startFestYear(
                name: name.trimmingCharacters(in: .whitespaces),
                tagline: tagline.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : tagline.trimmingCharacters(in: .whitespaces),
                startDate: festISOFormatter.string(from: startDate),
                endDate: festISOFormatter.string(from: endDate),
                copyFromYear: copyFrom
            )
            // ⚠️ A partial copy reports itself. The year EXISTS either way — the
            // important part succeeded — but silently reporting plain success
            // after a table failed to copy is how a half-copied fest looks
            // finished.
            if let warning = out.warning {
                error = warning
            } else {
                result = out.copied > 0
                    ? "Created, and copied \(out.copied) items forward."
                    : "Created. Nothing to copy — plan it from scratch."
                Haptics.success()
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - This year's theme & cover (migration 0219)

/// Every column is nullable and null means "use the built-in look", so clearing
/// a field here is a real answer, not an empty form.
struct FestYearLookEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var theme = ""
    @State private var coverUrl = ""
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false

    private var service: FestContentService { env.festContentService }

    var body: some View {
        Form {
            Section {
                TextField("Theme", text: $theme)
            } header: {
                Text("This year's theme")
            } footer: {
                Text("The line people remember the year by — \u{201C}Ye Olde Family Feste\u{201D}. Leave it empty for no theme.")
            }

            Section {
                TextField("Cover image URL", text: $coverUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Cover photo")
            } footer: {
                Text("This year's own cover, kept with the year — so next year's poster never replaces the one the archive shows. Empty falls back to the classic art.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Theme & cover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                }
                .disabled(saving)
            }
        }
        .task {
            await service.load()
            guard !loaded else { return }
            theme = service.config?.theme ?? ""
            coverUrl = service.config?.coverUrl ?? ""
            loaded = true
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await service.saveYearLook(
                theme: theme.trimmingCharacters(in: .whitespaces).isEmpty ? nil : theme,
                coverUrl: coverUrl.trimmingCharacters(in: .whitespaces).isEmpty ? nil : coverUrl
            )
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
