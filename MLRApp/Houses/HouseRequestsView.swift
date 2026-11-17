import SwiftUI
import PhotosUI
import Kingfisher

// MARK: - House requests board (migrations 0194–0208)
//
// The board a house's members file asks on and its House Admins work through.
//
// ⚠️ Grouped by what someone still has to DO, not by when rows were created.
// "Approved — still to do" is the load-bearing group: "approved but nobody
// bought it" is the exact failure this whole feature exists to make visible.

struct HouseRequestsView: View {
    @Environment(AppEnvironment.self) private var env
    let house: House

    @State private var composing = false
    @State private var showTombstones = false

    private var service: HouseRequestsService { env.houseRequestsService }

    private func rows(_ group: HouseRequest.Group) -> [HouseRequest] {
        service.requests.filter { $0.group == group }
    }

    var body: some View {
        List {
            if let error = service.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.orange)
                }
            }

            approverNote

            ForEach(HouseRequest.Group.allCases, id: \.self) { group in
                let items = rows(group)
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { request in
                            NavigationLink(destination: HouseRequestDetailView(request: request, house: house)) {
                                HouseRequestRow(request: request)
                            }
                        }
                    }
                }
            }

            if service.requests.isEmpty && !service.loading && service.loadError == nil {
                Section {
                    VStack(spacing: 6) {
                        Text("Nothing on the board")
                            .font(.mlrScaled(15, weight: .semibold))
                        Text("Ideas, things the house should buy, and money you're owed back all go here.")
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }

            // A removed request is restorable for 7 days (0208) — a tombstone,
            // not a disappearance, so an accidental delete is recoverable.
            if service.canReview, !service.tombstones.isEmpty {
                Section {
                    DisclosureGroup("Recently removed (\(service.tombstones.count))",
                                    isExpanded: $showTombstones) {
                        ForEach(service.tombstones) { request in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.title).font(.mlrScaled(14))
                                    Text("\(request.tombstoneDaysLeft()) days left to restore")
                                        .font(.mlrScaled(11))
                                        .foregroundStyle(Color.mlrTextMuted)
                                }
                                Spacer()
                                Button("Restore") {
                                    Task {
                                        try? await service.restore(id: request.id)
                                        await service.load(houseId: house.id, force: true)
                                    }
                                }
                                .font(.mlrScaled(12, weight: .semibold))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Filing a request while previewing would file it as the real
                // admin under someone else's name on screen.
                if !env.isPreviewing {
                    Button { composing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New request")
                }
            }
        }
        .sheet(isPresented: $composing) {
            NavigationStack { HouseRequestComposer(house: house) }
        }
        .refreshable { await service.load(houseId: house.id, force: true) }
        .task { await service.load(houseId: house.id, force: true) }
    }

    /// ⚠️ Names the recipients BEFORE anything is sent, and says so loudly when
    /// there are none — a house with no House Admin notifies nobody, and finding
    /// that out after filing a request is how a request sits unread for a week.
    @ViewBuilder
    private var approverNote: some View {
        Section {
            if service.approverNames.isEmpty {
                Label("This house has no House Admin yet, so nobody is notified about new requests. An app admin in this house can appoint one.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.mlrScaled(12))
                    .foregroundStyle(.orange)
            } else {
                Label("Decided by \(service.approverNames.joined(separator: ", "))",
                      systemImage: "person.badge.shield.checkmark")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
            }

            // ⚠️ Only an app admin who is THEMSELVES IN THIS HOUSE may appoint a
            // House Admin — enforced server-side by `set_house_admin`, and
            // mirrored here so the control isn't offered to someone it will
            // reject. An app admin from another house is not an authority here.
            if env.isAdmin, env.currentProfile?.houseId == house.id {
                NavigationLink(destination: HouseAdminsView(house: house)) {
                    Label("Who can decide requests", systemImage: "person.2.badge.gearshape")
                        .font(.mlrScaled(13))
                }
            }
        }
    }
}

// MARK: - Appointing House Admins (migration 0194)

struct HouseAdminsView: View {
    @Environment(AppEnvironment.self) private var env
    let house: House

    @State private var members: [Profile] = []
    @State private var loading = true
    @State private var busyId: UUID?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("A House Admin decides this house's requests — ideas, purchases and reimbursements. App admins from other houses deliberately have no say here.")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
            }

            Section {
                if loading {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(Color.mlrTextMuted) }
                } else if members.isEmpty {
                    Text("Nobody is assigned to this house yet.")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextMuted)
                } else {
                    ForEach(members) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            if busyId == member.id {
                                ProgressView()
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { member.houseAdmin },
                                    set: { on in Task { await set(member, on) } }
                                ))
                                .labelsHidden()
                                .tint(Color.mlrPineText)
                            }
                        }
                    }
                }
            } header: {
                Text("In this house")
            } footer: {
                Text("Moving someone to a different house clears this automatically.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("House Admins")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // ⚠️ Compares `house_id` DIRECTLY rather than going through
            // `is_house_member()`, which grants app admins a blanket pass and
            // would list people from other houses.
            members = try await supabase.from("profiles")
                .select("*")
                .eq("house_id", value: house.id.uuidString)
                .order("display_name", ascending: true)
                .execute().value
        } catch {
            self.error = "Couldn't load this house's members."
        }
    }

    private func set(_ member: Profile, _ value: Bool) async {
        busyId = member.id
        error = nil
        defer { busyId = nil }
        do {
            try await env.houseRequestsService.setHouseAdmin(target: member.id, value: value)
            await load()
            await env.houseRequestsService.load(houseId: house.id, force: true)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Board row

private struct HouseRequestRow: View {
    let request: HouseRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(request.kind.meta.emoji).font(.mlrScaled(20))

            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .font(.mlrScaled(15, weight: .semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    // The whose-money badge. Reads correctly to a third party —
                    // most views of a request are by somebody else.
                    Text(request.kind.meta.money)
                        .font(.mlrScaled(10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mlrAccent.mlrTint(0.15))
                        .foregroundStyle(Color.mlrAccent)
                        .clipShape(Capsule())

                    if let cost = request.cost {
                        Text(cost, format: .currency(code: "USD"))
                            .font(.mlrScaled(11, weight: .medium))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                    if request.testOnly {
                        Text("TEST")
                            .font(.mlrScaled(9, weight: .black))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.mlrTextMuted.mlrTint(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(request.statusLabel)
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)

                // Names the ACTOR — the failure this feature prevents is
                // everyone assuming somebody else has it.
                if let next = request.nextStep {
                    Text(next)
                        .font(.mlrScaled(11, weight: .medium))
                        .foregroundStyle(Color.mlrAccent)
                }

                if let who = request.createdByName {
                    Text("from \(who)")
                        .font(.mlrScaled(10))
                        .foregroundStyle(Color.mlrTextMuted.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared helpers

/// Money text -> amount, the way web reads it: strip everything but digits and
/// the point, so "$1,240.50" works. nil when it isn't a non-negative number.
private func parseMoney(_ text: String) -> Double? {
    let cleaned = text.filter { $0.isNumber || $0 == "." }
    guard let n = Double(cleaned), n >= 0 else { return nil }
    return n
}

/// Uploads picked photos (mini, category "work" — web's category) then attaches
/// each through `add_house_request_media`. Returns how many failed; the request
/// itself is already saved by then, so a failure means "this photo didn't attach".
@MainActor
private func attachPhotos(_ items: [PhotosPickerItem], to requestId: UUID,
                          startingAt position: Int, env: AppEnvironment) async -> Int {
    var failed = 0
    var pos = position
    for item in items {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { failed += 1; continue }
        do {
            let res = try await env.mediaService.uploadWorkImage(image: image)
            try await env.houseRequestsService.addMedia(requestId: requestId, url: res.url, type: "image",
                                                        thumbnailUrl: res.thumbnailUrl, position: pos)
            pos += 1
        } catch {
            failed += 1
        }
    }
    return failed
}

private func photoFailureMessage(_ failed: Int) -> String {
    "Saved, but \(failed == 1 ? "1 photo didn't" : "\(failed) photos didn't") attach. You can add \(failed == 1 ? "it" : "them") from the request itself."
}

// MARK: - Composer

/// ⚠️ THERE IS NO DEFAULT KIND. Picking one is its own step and the form does
/// not exist until you've chosen — three tiles that differ only by a noun and an
/// emoji cannot teach anyone the difference, so each one states the deal.
struct HouseRequestComposer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let house: House

    @State private var kind: HouseRequestKind?
    @State private var title = ""
    @State private var reason = ""
    @State private var cost = ""
    @State private var quantity = ""
    @State private var testOnly = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var saving = false
    @State private var error: String?

    private var service: HouseRequestsService { env.houseRequestsService }

    /// A reimbursement without an amount can't be acted on (0195 rejects it
    /// server-side too) — the friendly version of the same rule. It's the TOTAL
    /// of the receipt, not a per-item price.
    private var canSend: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !saving else { return false }
        if kind == .reimbursement { return (parseMoney(cost) ?? 0) > 0 }
        return true
    }

    var body: some View {
        Group {
            if let kind {
                form(for: kind)
            } else {
                chooser
            }
        }
        .navigationTitle(kind == nil ? "What kind of ask?" : "New request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if kind != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if saving { ProgressView() } else { Text("Send").fontWeight(.semibold) }
                    }
                    .disabled(!canSend)
                }
            }
        }
    }

    private var chooser: some View {
        List {
            ForEach(HouseRequestKind.chooserOrder) { k in
                Button {
                    withAnimation { kind = k }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(k.meta.emoji).font(.mlrScaled(28))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(k.meta.ask)
                                .font(.mlrScaled(15, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                            // The load-bearing sentence: whose money, and who
                            // places the order.
                            Text(k.meta.deal)
                                .font(.mlrScaled(12))
                                .foregroundStyle(Color.mlrTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func form(for k: HouseRequestKind) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Text(k.meta.emoji).font(.mlrScaled(22))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(k.meta.label).font(.mlrScaled(14, weight: .semibold))
                        Text(k.meta.deal)
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Change") { withAnimation { kind = nil } }
                        .font(.mlrScaled(12, weight: .semibold))
                        .buttonStyle(.borderless)
                }
            } footer: {
                Text("You: \(k.meta.youDo)\nA House Admin: \(k.meta.adminDoes)")
            }

            Section {
                TextField("What is it?", text: $title)
                TextField("Why (optional)", text: $reason, axis: .vertical)
                    .lineLimit(2...5)
            }

            // ⚠️ An idea deliberately has NO cost field. A price box on a
            // "wouldn't it be nice if" is exactly the friction that stops ideas
            // being written down.
            if k.hasMoney {
                Section {
                    TextField(k == .reimbursement ? "What you paid" : "Rough cost",
                              text: $cost)
                        .keyboardType(.decimalPad)
                    TextField("How many (optional)", text: $quantity)
                        .keyboardType(.numberPad)
                } header: {
                    Text(k == .reimbursement ? "The amount" : "The estimate")
                }
            }

            Section {
                PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 10, matching: .images) {
                    Label(pickedPhotos.isEmpty
                          ? (k == .reimbursement ? "Add a photo of the receipt" : "Add photos")
                          : "\(pickedPhotos.count) photo\(pickedPhotos.count == 1 ? "" : "s") selected",
                          systemImage: "photo.on.rectangle.angled")
                }
            } header: {
                Text("Photos (optional)")
            }

            // Only people who can review see the testing switch, as on web (0200).
            // Everyone still sees who a real send will reach.
            Section {
                if service.canReview {
                    Toggle("Just testing — only notify me", isOn: $testOnly)
                }
            } footer: {
                Text(service.canReview && testOnly
                     ? "Nobody else is notified, and only you can see this one."
                     : "Sends a notice to: \(service.approverNames.isEmpty ? "nobody — this house has no House Admin yet" : service.approverNames.joined(separator: ", "))")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func send() async {
        guard let kind else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let id = try await service.create(
                houseId: house.id,
                kind: kind,
                title: title.trimmingCharacters(in: .whitespaces),
                reason: reason.trimmingCharacters(in: .whitespaces),
                estCost: parseMoney(cost),
                quantity: Int(quantity.trimmingCharacters(in: .whitespaces)),
                // The switch is hidden from non-reviewers; never send a stale true.
                testOnly: service.canReview && testOnly
            )
            let failed = await attachPhotos(pickedPhotos, to: id, startingAt: 0, env: env)
            await service.load(houseId: house.id, force: true)
            if failed > 0 {
                // The request exists; stay open so the message is read, not lost.
                pickedPhotos = []
                error = photoFailureMessage(failed)
                return
            }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Detail

struct HouseRequestDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private let seed: HouseRequest
    let house: House

    init(request: HouseRequest, house: House) {
        self.seed = request
        self.house = house
    }

    /// Live copy from the board, so an edit or a new photo shows without leaving.
    private var request: HouseRequest {
        env.houseRequestsService.requests.first { $0.id == seed.id } ?? seed
    }

    @State private var note = ""
    @State private var notifyDecision = true
    @State private var editing = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var working = false
    @State private var error: String?
    @State private var converting = false
    @State private var paidAmount = ""

    private var service: HouseRequestsService { env.houseRequestsService }
    /// "Is this mine?" resolves through the EFFECTIVE user id, so an admin
    /// previewing as someone else sees that person's view of the request.
    private var isMine: Bool { env.effectiveUserId == request.createdBy }

    /// ⚠️ Every write no-ops while previewing. The write would land as the REAL
    /// admin, but the screen is pretending to be someone else — so approving a
    /// purchase "as Cass" would actually approve it, for real, from an admin who
    /// thought they were only looking.
    private var canAct: Bool { !env.isPreviewing }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Text(request.kind.meta.emoji).font(.mlrScaled(26))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.title).font(.mlrScaled(17, weight: .bold))
                        // Every surface that shows a kind shows the deal.
                        Text(request.kind.meta.deal)
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !request.reason.isEmpty {
                    Text(request.reason).font(.mlrScaled(14))
                }
                if let cost = request.cost {
                    LabeledContent(request.actualCost != nil ? "Actual" : "Estimate") {
                        Text(cost, format: .currency(code: "USD"))
                    }
                }
                if let q = request.quantity {
                    LabeledContent("Quantity") { Text("\(q)") }
                }
            }

            Section("Where it's at") {
                LabeledContent("Status") { Text(request.statusLabel) }
                if let next = request.nextStep {
                    Text(next)
                        .font(.mlrScaled(13, weight: .medium))
                        .foregroundStyle(Color.mlrAccent)
                }
                if let who = request.createdByName {
                    LabeledContent("Asked by") { Text(who) }
                }
                if let reviewer = request.reviewedByName {
                    LabeledContent("Decided by") { Text(reviewer) }
                }
                if let n = request.reviewNote, !n.isEmpty {
                    LabeledContent("Note") { Text(n) }
                }
                if let n = request.changeNote, !n.isEmpty {
                    LabeledContent("Changed") { Text(n) }
                }
            }

            if !request.links.isEmpty {
                Section("Links") {
                    ForEach(request.links, id: \.href) { link in
                        if let url = URL(string: link.href) {
                            Link(link.label ?? link.href, destination: url)
                        }
                    }
                }
            }

            photosSection

            decisionSection
            progressSection
            requesterSection

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(request.kind.meta.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Change it") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { HouseRequestEditSheet(request: request, house: house, asReviewer: service.canReview && !isMine) }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .disabled(working)
    }

    /// Web (`update_house_request`, 0207): a House Admin may change any request
    /// at any status; the requester only while it's pending or approved. App
    /// admins who aren't this house's House Admin get nothing.
    private var canEdit: Bool {
        guard canAct, !request.isDeleted else { return false }
        if service.canReview { return true }
        return isMine && (request.status == .pending || request.status == .approved)
    }

    /// Requester or a reviewer may attach (add_house_request_media).
    private var canAttach: Bool { canAct && !request.isDeleted && (isMine || service.canReview) }

    @ViewBuilder
    private var photosSection: some View {
        let visible = request.media.filter { $0.status != "hidden" }
        if !visible.isEmpty || canAttach {
            Section("Photos & receipts") {
                if !visible.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(visible) { m in
                            photoTile(m)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if canAttach {
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 10, matching: .images) {
                        Label("Add photos", systemImage: "photo.badge.plus")
                    }
                }
            }
        }
    }

    private func photoTile(_ m: HouseRequestMedia) -> some View {
        let canRemove = canAct && (m.uploadedBy == env.effectiveUserId || isMine || service.canReview)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let url = env.mediaTokenService.url(m.thumbnailUrl ?? m.storagePath) {
                    KFImage(url).resizable().scaledToFill()
                } else {
                    Color.mlrTextMuted.opacity(0.15)
                }
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if m.isHeld {
                    Text("Held")
                        .font(.mlrScaled(9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(MLRChipFill(), in: Capsule())
                        .padding(4)
                }
            }
            if canRemove {
                Button {
                    Task { await run { try await service.removeMedia(mediaId: m.id) } }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 20))
                }
                .buttonStyle(.borderless)
                .padding(4)
                .accessibilityLabel("Remove photo")
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        working = true
        error = nil
        defer { working = false; pickedPhotos = [] }
        let failed = await attachPhotos(items, to: request.id, startingAt: request.media.count, env: env)
        await service.load(houseId: house.id, force: true)
        if failed > 0 {
            error = failed == 1 ? "1 photo didn't attach." : "\(failed) photos didn't attach."
        } else {
            Haptics.success()
        }
    }

    /// House Admins only. ⚠️ App admins deliberately have no authority here —
    /// `canReview` comes from `profiles.house_admin` for THIS house.
    @ViewBuilder
    private var decisionSection: some View {
        if service.canReview, canAct, request.status == .pending {
            Section("Your decision") {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                Toggle("Email \(request.createdByName ?? "them") the decision", isOn: $notifyDecision)
                    .tint(Color.mlrPineText)
                Text(tellsLine)
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)
                Button(request.kind.decideLabels.approve) {
                    Task { await decide(approve: true) }
                }
                .fontWeight(.semibold)
                Button(request.kind.decideLabels.deny, role: .destructive) {
                    Task { await decide(approve: false) }
                }
            }
        }
    }

    /// "Tells: …" — who hears about a decision, BEFORE it is sent. Same source as
    /// the composer footer (the house's House Admins), leaving out the requester
    /// and the person deciding, as web's TellsLine does.
    private var tellsLine: String {
        let who = request.createdByName ?? "the requester"
        let others = service.approvers
            .filter { $0.id != env.effectiveUserId && $0.id != request.createdBy }
            .map(\.name)
        if service.approvers.isEmpty {
            return "Tells: \(who). This house has no House Admin, so nobody else will be told."
        }
        if others.isEmpty { return "Tells: \(who) — nobody else." }
        return "Tells: \(who), and \(others.joined(separator: ", ")) (\(others.count == 1 ? "the other House Admin" : "the other House Admins"))."
    }

    /// ⚠️ The ladder is per kind. A purchase goes `approved → ordered`, which is
    /// TERMINAL — there is deliberately no "it arrived" step. A reimbursement
    /// goes straight to `received` ("Paid"), skipping `ordered` entirely. An
    /// IDEA ends at `approved` and gets no third step at all, because offering
    /// one invents a chore nobody owes.
    @ViewBuilder
    private var progressSection: some View {
        if service.canReview, canAct, request.status == .approved, request.kind != .idea {
            Section("Next step") {
                if request.kind == .purchase {
                    Button("Mark it ordered") {
                        Task { await progress(.ordered) }
                    }
                    .fontWeight(.semibold)
                } else {
                    Button("Mark it paid") {
                        Task { await progress(.received) }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var requesterSection: some View {
        // ⚠️ Converting a purchase into a reimbursement is REQUESTER-ONLY. A
        // reimbursement pays `created_by`, so anyone else converting would route
        // the money to whoever ASKED rather than whoever PAID.
        if isMine, canAct, request.kind == .purchase,
           request.status == .pending || request.status == .approved {
            Section("I bought it myself") {
                if converting {
                    TextField("What you actually paid", text: $paidAmount)
                        .keyboardType(.decimalPad)
                    if let paid = parseMoney(paidAmount), conversionNeedsReapproval(paid) {
                        Label(reapprovalText, systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrScaled(12))
                            .foregroundStyle(.orange)
                    }
                    Button("Ask to be paid back") {
                        Task { await convert() }
                    }
                    .fontWeight(.semibold)
                    .disabled((parseMoney(paidAmount) ?? 0) <= 0)
                } else {
                    Button("I already bought this — pay me back") {
                        withAnimation { converting = true }
                    }
                }
            }
        }

        if isMine, canAct, request.status == .pending {
            Section {
                Button("Withdraw this request", role: .destructive) {
                    Task { await run { try await service.withdraw(id: request.id) } }
                }
            }
        }

        // Mirrors web's `canDeleteRequest` / 0208's `delete_house_request`: the
        // requester may remove their own at ANY status, a House Admin any in the
        // house, and nobody else (app admins included). Soft delete, 7-day tombstone.
        if (isMine || service.canReview), canAct, !request.isDeleted {
            Section {
                Button("Remove from the board", role: .destructive) {
                    Task { await run { try await service.delete(id: request.id) } }
                }
            } footer: {
                Text("It stays restorable for 7 days.")
            }
        }
    }

    /// Mirrors web's `conversionNeedsReapproval` and 0207's
    /// `_house_request_overspend_grace()` ($25) — only used to TELL the requester
    /// before they submit; the server decides.
    private static let overspendGrace = 25.0

    private func conversionNeedsReapproval(_ actual: Double) -> Bool {
        if request.status != .approved { return true }   // nothing approved yet
        guard let est = request.estCost else { return false }  // no ceiling to breach
        return actual > est + Self.overspendGrace
    }

    private var reapprovalText: String {
        if request.status != .approved {
            return "This hasn't been approved yet, so it goes back to a House Admin to decide."
        }
        return "That's more than $\(Int(Self.overspendGrace)) over the approved estimate, so it goes back to a House Admin for another look before it's paid."
    }

    private func decide(approve: Bool) async {
        await run {
            try await service.review(id: request.id, approve: approve,
                                     note: note.isEmpty ? nil : note, notify: notifyDecision)
        }
    }

    private func progress(_ status: HouseRequestStatus) async {
        await run { try await service.setProgress(id: request.id, status: status) }
    }

    private func convert() async {
        guard let amount = parseMoney(paidAmount), amount > 0 else { return }
        await run { try await service.convertToReimbursement(id: request.id, actualCost: amount) }
    }

    private func run(_ work: () async throws -> Void) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await work()
            await service.load(houseId: house.id, force: true)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Edit ("Change it")

/// Web's edit sheet (`update_house_request`). A House Admin can correct any
/// request ("yes, but two of them") and may leave a note and choose whether the
/// requester is emailed; the requester can fix their own while pending/approved.
/// The kind is fixed — reclassifying would invalidate the fields already filled.
struct HouseRequestEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let request: HouseRequest
    let house: House
    /// A reviewer editing SOMEONE ELSE'S request: the note + notify controls show.
    let asReviewer: Bool

    @State private var title: String
    @State private var reason: String
    @State private var links: [EditLink]
    @State private var cost: String
    @State private var quantity: String
    @State private var changeNote = ""
    @State private var notify = true
    @State private var saving = false
    @State private var error: String?

    struct EditLink: Identifiable {
        let id = UUID()
        var href: String
        var label: String
    }

    init(request: HouseRequest, house: House, asReviewer: Bool) {
        self.request = request
        self.house = house
        self.asReviewer = asReviewer
        _title = State(initialValue: request.title)
        _reason = State(initialValue: request.reason)
        _links = State(initialValue: request.links.map { EditLink(href: $0.href, label: $0.label ?? "") })
        _cost = State(initialValue: request.estCost.map { String($0) } ?? "")
        _quantity = State(initialValue: request.quantity.map(String.init) ?? "")
    }

    private var service: HouseRequestsService { env.houseRequestsService }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !saving else { return false }
        if request.kind == .reimbursement { return (parseMoney(cost) ?? 0) > 0 }
        return true
    }

    var body: some View {
        Form {
            Section {
                TextField("What is it?", text: $title)
                TextField("Why", text: $reason, axis: .vertical)
                    .lineLimit(2...5)
            }

            if request.kind.hasMoney {
                Section {
                    TextField(request.kind == .reimbursement ? "What you paid" : "Rough cost", text: $cost)
                        .keyboardType(.decimalPad)
                    if request.kind == .purchase {
                        TextField("How many (optional)", text: $quantity)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text(request.kind == .reimbursement ? "The amount" : "The estimate")
                }
            }

            Section("Links") {
                ForEach($links) { $link in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("https://…", text: $link.href)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Button text (optional)", text: $link.label)
                            .font(.mlrScaled(13))
                    }
                }
                .onDelete { links.remove(atOffsets: $0) }
                Button { links.append(EditLink(href: "", label: "")) } label: {
                    Label("Add a link", systemImage: "plus.circle")
                }
            }

            if asReviewer {
                Section {
                    TextField("Why you changed it (optional)", text: $changeNote, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("Email \(request.createdByName ?? "them") the change", isOn: $notify)
                        .tint(Color.mlrPineText)
                } footer: {
                    Text("They get an in-app notice and a push either way.")
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Change it")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                }
                .disabled(!canSave)
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }

        let cleaned: [CalloutLink] = links.compactMap { l in
            var href = l.href.trimmingCharacters(in: .whitespaces)
            guard !href.isEmpty else { return nil }
            if !href.contains(":") { href = "https://" + href }
            let label = l.label.trimmingCharacters(in: .whitespaces)
            return CalloutLink(href: href, label: label.isEmpty ? nil : label)
        }

        // An idea carries no cost; clear one only when the field was emptied.
        let newCost = request.kind.hasMoney ? parseMoney(cost) : nil
        let newQty = request.kind == .purchase ? Int(quantity.trimmingCharacters(in: .whitespaces)) : nil
        let clearCost = request.kind.hasMoney && newCost == nil && request.estCost != nil
        let clearQty = request.kind == .purchase && (newQty ?? 0) < 1 && request.quantity != nil

        do {
            try await service.update(
                id: request.id,
                title: title.trimmingCharacters(in: .whitespaces),
                reason: reason.trimmingCharacters(in: .whitespaces),
                links: cleaned,
                estCost: newCost,
                quantity: (newQty ?? 0) >= 1 ? newQty : nil,
                clearCost: clearCost,
                clearQuantity: clearQty,
                note: asReviewer ? (changeNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : changeNote) : nil,
                notify: asReviewer ? notify : true
            )
            await service.load(houseId: house.id, force: true)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
