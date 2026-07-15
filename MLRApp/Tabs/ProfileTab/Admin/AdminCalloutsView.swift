import SwiftUI

// MARK: - AdminCalloutsView
// Manage Home callout cards (migration 0083 / 0093). Lists current callouts with
// status badges, lets admins create new ones or archive existing ones.

struct AdminCalloutsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var composing = false
    @State private var editing: HomeCallout? = nil

    private var callouts: [HomeCallout] {
        env.festContentService.callouts.sorted { $0.position < $1.position }
    }

    var body: some View {
        List {
            if callouts.isEmpty {
                Text("No callout cards yet. Tap + to create one.")
                    .font(.mlrScaled(14))
                    .foregroundStyle(Color.mlrTextMuted)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(callouts) { callout in
                    Button { editing = callout } label: {
                        calloutRow(callout)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Home Callouts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { composing = true } label: {
                    Image(systemName: "plus")
                }
                .tint(Color.mlrPrimary)
            }
        }
        .sheet(isPresented: $composing, onDismiss: { Task { await env.festContentService.reload() } }) {
            NavigationStack { CalloutComposerView(existing: nil) }
        }
        .sheet(item: $editing, onDismiss: { Task { await env.festContentService.reload() } }) { callout in
            NavigationStack { CalloutComposerView(existing: callout) }
        }
        .task { await env.festContentService.load() }
    }

    private func calloutRow(_ callout: HomeCallout) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(callout.title ?? "(no title)")
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(callout.isActive ? Color.mlrText : Color.mlrTextMuted)
                    if !callout.isActive {
                        Text("OFF")
                            .font(.mlrScaled(9, weight: .bold))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.mlrSurface)
                            .clipShape(Capsule())
                    }
                }
                if let body = callout.body {
                    Text(body)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let ends = callout.endsOn {
                        Text("Ends \(ends)")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                    if !callout.links.isEmpty {
                        Text("\(callout.links.count) link\(callout.links.count == 1 ? "" : "s")")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextSubtle)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - CalloutComposerView
// Create or edit a Home callout card. Supports title, body, image URL,
// multiple links (migration 0093), date range, active toggle.

struct CalloutComposerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let existing: HomeCallout?

    @State private var title = ""
    @State private var body_ = ""
    @State private var imageUrl = ""
    @State private var links: [CalloutLink] = []
    @State private var startsOn = ""
    @State private var endsOn = ""
    @State private var isActive = true
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteAlert = false

    private var isNew: Bool { existing == nil }

    var body: some View {
        Form {
            Section("Card Content") {
                LabeledContent("Title") {
                    TextField("T-shirts on sale · Work weekend", text: $title)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Body") {
                    TextField("Short description…", text: $body_, axis: .vertical)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2...3)
                }
                LabeledContent("Image URL") {
                    TextField("https://…", text: $imageUrl)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            Section {
                ForEach(Array(links.enumerated()), id: \.offset) { idx, link in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Label (optional)", text: Binding(
                            get: { links[idx].label ?? "" },
                            set: { links[idx].label = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.mlrScaled(13))
                        TextField("https:// or tel: or mailto:", text: Binding(
                            get: { links[idx].href },
                            set: { links[idx].href = $0 }
                        ))
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { links.remove(at: idx) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button { links.append(CalloutLink(href: "", label: nil)) } label: {
                    Label("Add Link", systemImage: "plus")
                        .foregroundStyle(Color.mlrPrimary)
                }
            } header: {
                Text("Action Links")
            }

            Section("Visibility") {
                LabeledContent("Starts On") {
                    TextField("yyyy-MM-dd (optional)", text: $startsOn)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Ends On") {
                    TextField("yyyy-MM-dd (optional)", text: $endsOn)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Toggle("Active", isOn: $isActive)
                    .tint(Color.mlrPrimary)
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrDanger)
                }
            }

            if !isNew {
                Section {
                    Button(role: .destructive) { showDeleteAlert = true } label: {
                        Text("Delete Callout")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Callout" : "Edit Callout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                }
            }
        }
        .alert("Delete this callout?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { seed() }
    }

    private func seed() {
        guard let c = existing else { return }
        title    = c.title ?? ""
        body_    = c.body ?? ""
        imageUrl = c.imageUrl ?? ""
        links    = c.links
        startsOn = c.startsOn ?? ""
        endsOn   = c.endsOn ?? ""
        isActive = c.isActive
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        struct LinkPayload: Encodable {
            let href: String
            let label: String?
        }
        struct CalloutPayload: Encodable {
            var id: String?
            var title: String?
            var body: String?
            var image_url: String?
            var links: [LinkPayload]
            var starts_on: String?
            var ends_on: String?
            var is_active: Bool
            var dismiss_id: String?
            var position: Int?
        }

        let validLinks = links.filter { !$0.href.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { LinkPayload(href: $0.href, label: $0.label) }

        let payload = CalloutPayload(
            id:         existing?.id,
            title:      title.isEmpty    ? nil : title,
            body:       body_.isEmpty    ? nil : body_,
            image_url:  imageUrl.isEmpty ? nil : imageUrl,
            links:      validLinks,
            starts_on:  startsOn.isEmpty ? nil : startsOn,
            ends_on:    endsOn.isEmpty   ? nil : endsOn,
            is_active:  isActive,
            dismiss_id: existing?.dismissId,
            position:   existing?.position
        )
        do {
            if existing != nil {
                try await supabase.from("home_callouts").upsert(payload, onConflict: "id").execute()
            } else {
                try await supabase.from("home_callouts").insert(payload).execute()
            }
            dismiss()
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard let id = existing?.id else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await supabase.from("home_callouts").delete().eq("id", value: id).execute()
            dismiss()
        } catch {
            saveError = "Delete failed."
        }
    }
}
