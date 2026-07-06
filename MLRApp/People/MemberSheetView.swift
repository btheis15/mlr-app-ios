import SwiftUI

// MARK: - MemberSheetView
// Full member profile sheet: avatar, name, bio, contact + payment rows
// (all Protected for guests), birthday with no year, admin badge.
// If viewing your own profile, offers an "Edit Profile" link.

struct MemberSheetView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let member: Profile

    @State private var composeState: MessageComposeState?
    @State private var showAddContact = false
    @State private var birthdayAdded = false
    @State private var birthdayError: String?

    private var isOwnProfile: Bool {
        env.currentProfile?.id == member.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if let bio = member.bio, !bio.isEmpty {
                        bioSection(bio)
                    }

                    contactSection
                    paymentSection
                    birthdaySection

                    // Admin controls (make/remove admin, assign house, remove member) —
                    // admins only, and not on your own row. Replaces the old Admin → Members tab.
                    if env.isAdmin && !isOwnProfile {
                        MemberAdminCard(member: member) { dismiss() }
                    }

                    if isOwnProfile {
                        NavigationLink {
                            // Profile editing lives in the Profile tab; this is the entry point.
                            EditProfilePlaceholder()
                        } label: {
                            Text("Edit Profile")
                                .secondaryButton()
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .background(Color.mlrSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .messageComposer($composeState)
        .sheet(isPresented: $showAddContact) {
            AddToContactsView(name: member.name,
                              phone: member.phone,
                              email: member.email.isEmpty ? nil : member.email,
                              imageData: nil)
                .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(profile: member, size: .xlarge)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    PrivateName(profile: member,
                                font: .mlrScaled(24, weight: .bold))
                    if member.isAdmin {
                        Label("Admin", systemImage: "checkmark.seal.fill")
                            .font(.mlrScaled(12, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.mlrPrimaryLight)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bio

    private func bioSection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "About")
            Text(bio)
                .font(.mlrBody)
                .foregroundStyle(Color.mlrText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .cardStyle()
    }

    // MARK: - Contact

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Contact")
            Protected {
                VStack(spacing: 10) {
                    if let phone = member.phone, !phone.isEmpty {
                        let digits = phone.filter(\.isNumber)
                        contactRow("Call", MLRFormat.phone(phone), "phone.fill",
                                   url: "tel://\(digits)")
                        Button {
                            composeState = MessageComposeState(recipients: [phone], body: "")
                        } label: {
                            contactRowLabel("Text", MLRFormat.phone(phone),
                                            "message.fill", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if !member.email.isEmpty {
                        contactRow("Email", member.email, "envelope.fill",
                                   url: "mailto:\(member.email)")
                    }
                    if let address = member.address, !address.isEmpty {
                        let q = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        contactRow("Get directions", address, "mappin.and.ellipse",
                                   url: "http://maps.apple.com/?q=\(q)")
                    }

                    let hasPhone = !(member.phone?.isEmpty ?? true)
                    if hasPhone || !member.email.isEmpty {
                        Button {
                            showAddContact = true
                        } label: {
                            contactRowLabel("Add to Contacts", member.name,
                                            "person.crop.circle.badge.plus", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if (member.phone?.isEmpty ?? true) && member.email.isEmpty {
                        Text("No contact info on file.")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    // MARK: - Payment

    /// One payable method, for the data-driven list (so the member's Preferred
    /// one can float to the top + get a badge).
    private struct PayMethod: Identifiable {
        let key: String          // matches profiles.pay_preferred values
        let label: String
        let value: String
        let icon: String
        let url: String?
        var id: String { key }
    }

    /// The member's filled handles, Preferred first.
    private var payMethods: [PayMethod] {
        var list: [PayMethod] = []
        if let venmo = member.venmoHandle, !venmo.isEmpty {
            let h = venmo.replacingOccurrences(of: "@", with: "")
            list.append(.init(key: "Venmo", label: "Venmo", value: "@\(h)", icon: "dollarsign.circle.fill", url: "venmo://users/\(h)"))
        }
        if let zelle = member.zelleHandle, !zelle.isEmpty {
            list.append(.init(key: "Zelle", label: "Zelle", value: zelle, icon: "z.circle.fill", url: nil))
        }
        if let cash = member.appleCashHandle, !cash.isEmpty {
            list.append(.init(key: "Apple Cash", label: "Apple Cash", value: cash, icon: "applelogo", url: nil))
        }
        if let paypal = member.paypalHandle, !paypal.isEmpty {
            list.append(.init(key: "PayPal", label: "PayPal", value: paypal, icon: "p.circle.fill", url: nil))
        }
        let pref = member.payPreferred?.trimmingCharacters(in: .whitespaces).lowercased()
        return list.sorted { a, _ in a.key.lowercased() == pref }
    }

    @ViewBuilder
    private var paymentSection: some View {
        if member.hasPaymentHandle {
            let pref = member.payPreferred?.trimmingCharacters(in: .whitespaces).lowercased()
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Send a payment")
                Protected {
                    VStack(spacing: 10) {
                        ForEach(payMethods) { m in
                            contactRow(m.label, m.value, m.icon, url: m.url,
                                       preferred: m.key.lowercased() == pref)
                        }
                    }
                }
            }
            .padding(16)
            .cardStyle()
        }
    }

    // MARK: - Birthday (month + day, no year)

    @ViewBuilder
    private var birthdaySection: some View {
        if let birthday = member.birthday, let display = monthDay(from: birthday) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Birthday")
                Protected {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(display, systemImage: "gift.fill")
                            .font(.mlrBody)
                            .foregroundStyle(Color.mlrText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            Task { await addBirthday(birthday) }
                        } label: {
                            Label(birthdayAdded ? "Added to Calendar ✓" : "Add birthday to Calendar",
                                  systemImage: birthdayAdded ? "checkmark.circle.fill" : "calendar.badge.plus")
                                .font(.mlrScaled(13, weight: .semibold))
                                .foregroundStyle(birthdayAdded ? Color.mlrSuccess : Color.mlrPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(birthdayAdded)

                        if let birthdayError {
                            Text(birthdayError)
                                .font(.mlrCaption)
                                .foregroundStyle(Color.mlrDanger)
                        }
                    }
                }
            }
            .padding(16)
            .cardStyle()
        }
    }

    // MARK: - Row helper

    @ViewBuilder
    private func contactRow(_ label: String, _ value: String, _ icon: String, url: String?,
                            preferred: Bool = false) -> some View {
        let row = contactRowLabel(label, value, icon, showsChevron: url != nil, preferred: preferred)

        if let url, let link = URL(string: url) {
            Link(destination: link) { row }
        } else {
            row
        }
    }

    private func contactRowLabel(_ label: String, _ value: String, _ icon: String,
                                 showsChevron: Bool, preferred: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.mlrScaled(16))
                .foregroundStyle(Color.mlrPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                    if preferred {
                        Text("Preferred")
                            .font(.mlrScaled(10, weight: .bold))
                            .foregroundStyle(Color.mlrPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.mlrPrimary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(value)
                    .font(.mlrScaled(15, weight: .medium))
                    .foregroundStyle(Color.mlrText)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "arrow.up.right")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrTextSubtle)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Add birthday to Calendar

    private func addBirthday(_ iso: String) async {
        birthdayError = nil
        // CalendarService wants a full yyyy-MM-dd. If only MM-dd is stored,
        // anchor it to the current year (the yearly recurrence rule repeats it).
        let normalized: String
        if iso.count == 5 { // "MM-dd"
            let year = Calendar.current.component(.year, from: Date())
            normalized = "\(year)-\(iso)"
        } else {
            normalized = iso
        }
        do {
            _ = try await CalendarService.shared.addBirthday(memberName: member.name,
                                                             birthdayISO: normalized)
            Haptics.success()
            birthdayAdded = true
        } catch {
            Haptics.error()
            birthdayError = "Couldn't add to Calendar. Check Calendar access in Settings."
        }
    }

    // MARK: - Birthday parsing

    private func monthDay(from iso: String) -> String? {
        // Stored as "yyyy-MM-dd" or "MM-dd"; render "Month Day", no year.
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        var date = inFmt.date(from: iso)
        if date == nil {
            inFmt.dateFormat = "MM-dd"
            date = inFmt.date(from: iso)
        }
        guard let date else { return nil }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMMM d"
        return outFmt.string(from: date)
    }
}

// MARK: - MemberAdminCard
// Admin-only controls on a member's profile sheet: promote/demote admin, assign
// a house, and remove the account. Moved here from the old Admin → Members tab so
// there's a single member list (People). All gated server-side by the RPCs.

private struct MemberAdminCard: View {
    @Environment(AppEnvironment.self) private var env

    let member: Profile
    var onRemoved: () -> Void

    @State private var isAdmin: Bool
    @State private var houseId: UUID?
    @State private var working = false
    @State private var errorText: String?
    @State private var showRemove = false

    init(member: Profile, onRemoved: @escaping () -> Void) {
        self.member = member
        self.onRemoved = onRemoved
        _isAdmin = State(initialValue: member.isAdmin)
        _houseId = State(initialValue: member.houseId)
    }

    private var houseName: String? {
        env.housesService.houses.first { $0.id == houseId }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Admin")
            VStack(spacing: 0) {
                Button { Task { await toggleAdmin() } } label: {
                    row(isAdmin ? "Remove admin" : "Make admin",
                        icon: isAdmin ? "shield.slash.fill" : "shield.fill")
                }
                .buttonStyle(.plain)
                .disabled(working)

                Divider().padding(.leading, 44)

                Menu {
                    Button { Task { await setHouse(nil) } } label: {
                        Label("No house", systemImage: houseId == nil ? "checkmark" : "")
                    }
                    ForEach(env.housesService.houses) { h in
                        Button { Task { await setHouse(h.id) } } label: {
                            Label("\(h.emoji) \(h.name)", systemImage: houseId == h.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    row(houseName.map { "House · \($0)" } ?? "Assign house", icon: "house.fill")
                }
                .disabled(working)

                Divider().padding(.leading, 44)

                Button(role: .destructive) { showRemove = true } label: {
                    row("Remove member", icon: "trash.fill", tint: Color.mlrDanger)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            if let errorText {
                Text(errorText).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
            }
        }
        .padding(16)
        .cardStyle()
        .task { if env.housesService.houses.isEmpty { await env.housesService.fetchHouses() } }
        .alert("Remove member?", isPresented: $showRemove) {
            Button("Remove \(member.name)", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(member.name)'s account and all their data. This can't be undone.")
        }
    }

    private func row(_ title: String, icon: String, tint: Color = Color.mlrPrimary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.mlrScaled(15))
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .font(.mlrScaled(15, weight: .medium))
                .foregroundStyle(tint == Color.mlrDanger ? Color.mlrDanger : Color.mlrText)
            Spacer()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - Actions (server-gated RPCs)

    private func toggleAdmin() async {
        let newValue = !isAdmin
        working = true; errorText = nil; defer { working = false }
        do {
            struct P: Encodable { let target: String; let value: Bool }
            try await supabase.rpc("set_admin", params: P(target: member.id.uuidString, value: newValue)).execute()
            isAdmin = newValue
        } catch { errorText = "Couldn't update admin role." }
    }

    private func setHouse(_ hid: UUID?) async {
        working = true; errorText = nil; defer { working = false }
        do {
            try await env.housesService.setMemberHouse(target: member.id, houseId: hid)
            houseId = hid
        } catch { errorText = "Couldn't update house." }
    }

    private func remove() async {
        working = true; errorText = nil; defer { working = false }
        do {
            try await supabase.rpc("delete_member", params: ["target": member.id.uuidString]).execute()
            onRemoved()
        } catch { errorText = "Couldn't remove member." }
    }
}

// MARK: - Edit Profile placeholder destination

private struct EditProfilePlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.text.rectangle")
                .font(.mlrScaled(36))
                .foregroundStyle(Color.mlrPrimary)
            Text("Edit your profile from the Profile tab.")
                .font(.mlrBody)
                .foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlrSurface)
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}
