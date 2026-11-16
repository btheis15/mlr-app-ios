import SwiftUI

// MARK: - AdminLocalPlacesView
//
// Full manager for Local Places (table `local_places`, migration 0225):
// grouped list, drag to reorder (writes real `position` values), add, hide/show
// (`is_active`), delete with confirm + undo. When the table is missing the
// service is read-only and this screen says so instead of offering controls.

struct AdminLocalPlacesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = EditorListModel<LocalPlace>()
    @State private var editing: LocalPlace?
    @State private var adding = false
    @State private var errorText: String?

    private var service: LocalPlacesService { env.localPlacesService }

    private var groups: [String] {
        let present = Set(model.items.map(\.placeGroup))
        let known = LocalPlace.knownGroups.filter(present.contains)
        return known + present.subtracting(LocalPlace.knownGroups).sorted()
    }

    var body: some View {
        Group {
            if service.hasLoaded && !service.isEditable {
                ContentUnavailableView("Editing isn't available yet",
                                       systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("Editing becomes available once the database update is applied. Members still see the built-in list."))
            } else if !service.hasLoaded {
                ProgressView()
            } else {
                list
            }
        }
        .background(Color.mlrSurface)
        .navigationTitle("Local Places")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.persistOrder = { ids in try await service.saveOrder(ids: ids) }
            model.commitDelete = { place in try await service.delete(place) }
            model.title = { $0.name }
            await service.load(env: env)
            model.replace(service.places)
        }
        .onChange(of: service.places) { _, new in model.replace(new) }
        .sheet(item: $editing) { LocalPlaceEditor(place: $0, isNew: false) }
        .sheet(isPresented: $adding) { LocalPlaceEditor(place: .blank(), isNew: true) }
    }

    private var list: some View {
        List {
            if model.items.isEmpty {
                Section { Text("No places yet. Tap + to add one.").foregroundStyle(Color.mlrTextMuted) }
            }
            ForEach(groups, id: \.self) { g in
                EditorListSection(model, header: LocalPlace.groupTitle(g), group: { $0.placeGroup == g }) { place in
                    row(place)
                }
            }
        }
        .editorListChrome(model)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true; Haptics.tap() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a place")
            }
        }
        .alert("Couldn't update", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func row(_ place: LocalPlace) -> some View {
        Button { editing = place } label: {
            HStack(spacing: 12) {
                Text(place.displayEmoji).font(.mlrScaled(22)).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(place.name).font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrText)
                        if !place.isActive {
                            Text("Hidden")
                                .font(.mlrScaled(10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.mlrWarning.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.mlrWarning)
                        }
                    }
                    if let loc = place.locality, !loc.isEmpty {
                        Text(loc).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                    }
                }
                Spacer()
            }
            .opacity(place.isActive ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button { toggleVisible(place) } label: {
                Label(place.isActive ? "Hide" : "Show", systemImage: place.isActive ? "eye.slash" : "eye")
            }
            .tint(.mlrLake)
        }
        .contextMenu {
            Button { toggleVisible(place) } label: {
                Label(place.isActive ? "Hide from members" : "Show to members",
                      systemImage: place.isActive ? "eye.slash" : "eye")
            }
            Button(role: .destructive) { model.pendingConfirm = place } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityHint("Opens the editor")
    }

    private func toggleVisible(_ place: LocalPlace) {
        var p = place
        p.isActive.toggle()
        Haptics.select()
        Task {
            do { try await service.save(p, isNew: false) }
            catch { errorText = EditorError.message(error); Haptics.error() }
        }
    }
}

// MARK: - LocalPlaceEditor

struct LocalPlaceEditor: View {
    @Environment(AppEnvironment.self) private var env
    let isNew: Bool
    @State private var draft: EditorDraft<LocalPlace>
    @State private var phoneInput: String
    private let initialPhone: String
    @State private var groupChoice: String
    @State private var newGroupText = ""

    private static let newGroupTag = "__new__"

    init(place: LocalPlace, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: EditorDraft(place))
        let phone = place.phoneDisplay ?? place.phoneTel ?? ""
        _phoneInput = State(initialValue: phone)
        initialPhone = phone
        _groupChoice = State(initialValue: place.placeGroup)
    }

    private var service: LocalPlacesService { env.localPlacesService }

    private var groupOptions: [String] {
        var seen = LocalPlace.knownGroups
        for g in service.places.map(\.placeGroup) where !seen.contains(g) { seen.append(g) }
        if !seen.contains(draft.value.placeGroup), groupChoice != Self.newGroupTag { seen.append(draft.value.placeGroup) }
        return seen
    }

    private var phoneResult: PhoneFormat.Result? { PhoneFormat.normalize(phoneInput) }
    private var phoneBlank: Bool { phoneInput.trimmingCharacters(in: .whitespaces).isEmpty }
    private var phoneOK: Bool { phoneBlank || phoneResult != nil }

    private static func urlOK(_ s: String?) -> Bool {
        let t = s?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty || EditorLink.isValidURL(t)
    }

    private var hrefOK: Bool {
        let t = draft.value.internalHref?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty || t.hasPrefix("/")
    }

    private var groupOK: Bool {
        groupChoice != Self.newGroupTag || !newGroupText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var urlsOK: Bool {
        let v = draft.value
        return [v.website, v.menuUrl, v.orderUrl, v.bookingUrl, v.ratesUrl].allSatisfy(Self.urlOK)
    }

    private var canSave: Bool {
        !draft.value.name.trimmingCharacters(in: .whitespaces).isEmpty
            && phoneOK && urlsOK && hrefOK && groupOK
    }

    private var isDirty: Bool { draft.isDirty || phoneInput != initialPhone || (groupChoice == Self.newGroupTag && !newGroupText.isEmpty) }

    /// The place as members will see it: draft plus the normalised phone.
    private var preview: LocalPlace {
        var v = draft.value
        if let r = phoneResult { v.phoneTel = r.e164; v.phoneDisplay = r.display }
        else if phoneBlank { v.phoneTel = nil; v.phoneDisplay = nil }
        return v
    }

    var body: some View {
        EditorSheet(title: isNew ? "Add a place" : "Edit place",
                    isDirty: isDirty, canSave: canSave,
                    save: {
                        var v = preview
                        if groupChoice == Self.newGroupTag { v.placeGroup = newGroupText }
                        try await service.save(v, isNew: isNew)
                    }) {
            Section("What members will see") {
                LocalPlaceCard(place: preview)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section("Basics") {
                EditorTextField("Name", text: $draft.value.name, limit: 80, required: true)
                Picker("Section", selection: $groupChoice) {
                    ForEach(groupOptions, id: \.self) { Text(LocalPlace.groupTitle($0)).tag($0) }
                    Text("New section…").tag(Self.newGroupTag)
                }
                .onChange(of: groupChoice) { _, new in
                    if new != Self.newGroupTag { draft.value.placeGroup = new }
                }
                if groupChoice == Self.newGroupTag {
                    TextField("New section name", text: $newGroupText)
                        .onChange(of: newGroupText) { _, new in
                            draft.value.placeGroup = LocalPlacesService.normalizeGroup(new)
                        }
                }
                EditorTextField("Category line", text: $draft.value.category, placeholder: "What it is, e.g. Public 18-hole course", limit: 60)
                EditorTextField("Locality", text: $draft.value.locality, placeholder: "e.g. Tomahawk, WI", limit: 60)
                EditorTextField("Address", text: $draft.value.address, placeholder: "Street address (used for Directions)", limit: 120)
                EditorLongText("Blurb", text: $draft.value.blurb, limit: 300)
                EditorEmojiField("Emoji", emoji: $draft.value.emoji)
                accentPicker
                EditorImageField("Photo", url: $draft.value.imageUrl) { img in
                    try await service.uploadImage(img, using: env.mediaService)
                }
            }

            Section("Contact") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone").font(.mlrScaled(12, weight: .medium)).foregroundStyle(Color.mlrTextMuted)
                    TextField("Any format, e.g. 715 453 3130", text: $phoneInput)
                        .keyboardType(.phonePad)
                    if let r = phoneResult {
                        Label("Shows as \(r.display)", systemImage: "checkmark.circle.fill")
                            .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                    } else if !phoneBlank {
                        Label("That doesn't look like a real phone number.", systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    }
                }
                LinkField(label: "Website", text: $draft.value.website)
                LinkField(label: "Menu link", text: $draft.value.menuUrl)
                LinkField(label: "Order link", text: $draft.value.orderUrl)
            }

            Section("Booking and rates") {
                LinkField(label: "Booking link", text: $draft.value.bookingUrl)
                EditorTextField("Booking button label", text: $draft.value.bookingCta, placeholder: "Book tee time", limit: 24)
                LinkField(label: "Rates link", text: $draft.value.ratesUrl)
                EditorTextField("Rates button label", text: $draft.value.ratesCta, placeholder: "See rates", limit: 24)
            }

            Section {
                DisclosureGroup("Advanced: in-app hand-off") {
                    EditorTextField("In-app page", text: $draft.value.internalHref, placeholder: "/tee-times", autocapitalize: false)
                    if !hrefOK {
                        Text("Must start with /").font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    }
                    EditorTextField("Button label", text: $draft.value.internalCta, placeholder: "Tee Times", limit: 24)
                    Text("Only /tee-times opens a page inside the app today.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                }
            }

            Section {
                EditorToggle("Visible to members", isOn: $draft.value.isActive,
                             caption: "Hidden places stay here for admins but are not shown to members.")
            }
        }
    }

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accent").font(.mlrScaled(12, weight: .medium)).foregroundStyle(Color.mlrTextMuted)
            HStack(spacing: 14) {
                ForEach(LocalPlace.accentNames, id: \.self) { name in
                    Button { draft.value.accent = name; Haptics.select() } label: {
                        Circle().fill(LocalPlace.color(forAccent: name)).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Color.mlrBorder, lineWidth: 1))
                            .overlay {
                                if draft.value.accent == name {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name.capitalized)
                    .accessibilityAddTraits(draft.value.accent == name ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - URL field with validation and "Test link"

private struct LinkField: View {
    let label: String
    @Binding var text: String?
    @Environment(\.openURL) private var openURL

    private var trimmed: String { text?.trimmingCharacters(in: .whitespaces) ?? "" }
    private var valid: Bool { EditorLink.isValidURL(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditorTextField(label, text: $text, placeholder: "https://", keyboard: .URL, autocapitalize: false)
            if !trimmed.isEmpty {
                if valid {
                    Button("Test link") {
                        if let u = URL(string: trimmed) { openURL(u) }
                    }
                    .font(.mlrCaption).buttonStyle(.borderless)
                } else {
                    Text("Must start with http:// or https://")
                        .font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                }
            }
        }
    }
}
