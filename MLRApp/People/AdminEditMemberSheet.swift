import SwiftUI
import Supabase

// MARK: - AdminEditMemberSheet
//
// Admin backup for editing another member's profile when they can't (migration
// 0027 admin_set_member_profile). Gated by the two-admin unlock window (0025):
// editing another member's details needs two admins to unlock it, then any admin
// can edit for 24 hours. Mirrors the web AdminEditMember + AdminProfileOverride.
// Login-email changes are intentionally out of scope here (that path needs the
// mini auth server) — this edits profile fields only.

struct AdminEditMemberSheet: View {
    @Environment(\.dismiss) private var dismiss

    let member: Profile
    let onSaved: () -> Void

    // Editable profile fields (key, label, placeholder). Mirrors the web's set.
    private static let fields: [(key: String, label: String, placeholder: String)] = [
        ("display_name", "Name", ""),
        ("household", "Household / cabin", ""),
        ("phone", "Phone", "(715) 555-0123"),
        ("contact_email", "Contact email", "where to reach them"),
        ("venmo", "Venmo", ""),
        ("zelle", "Zelle", ""),
        ("cashapp", "Cash App", ""),
        ("paypal", "PayPal", ""),
        ("address", "Address", ""),
        ("bio", "Bio", ""),
    ]

    @State private var values: [String: String] = [:]
    @State private var appleCash = false
    @State private var unlockedUntil: Date?
    @State private var ready = false     // false until the override RPC answers
    @State private var loading = true
    @State private var busy = false
    @State private var status: String?

    private var isUnlocked: Bool {
        guard let u = unlockedUntil else { return false }
        return u > Date.now
    }
    private var hoursLeft: Int {
        guard let u = unlockedUntil else { return 0 }
        return max(1, Int((u.timeIntervalSinceNow / 3600).rounded()))
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(Color.mlrTextMuted) } }
                } else if !ready {
                    Section {
                        Label("The two-admin member-edit unlock isn't available yet.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.mlrWarning).font(.mlrScaled(13))
                    }
                } else if !isUnlocked {
                    lockedSection
                } else {
                    unlockedBanner
                    fieldsSection
                }

                if let status {
                    Section { Text(status).font(.mlrScaled(13)).foregroundStyle(Color.mlrPrimary) }
                }
            }
            .navigationTitle("Edit \(member.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if isUnlocked {
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else { Button("Save") { Task { await save() } }.fontWeight(.semibold) }
                    }
                }
            }
            .task { await loadOverride(); await loadProfile() }
        }
    }

    private var lockedSection: some View {
        Section {
            Text("Members manage their own profile — this is the backup for when someone can't. Editing another member's details needs two admins to unlock it; then any admin can edit for 24 hours.")
                .font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
            Button {
                Task { await runOverride("request_admin_override", note: "Your approval is recorded.") }
            } label: {
                Label("Approve unlock", systemImage: "lock.open.fill")
            }
            .disabled(busy)
        } header: { Text("Locked") }
    }

    private var unlockedBanner: some View {
        Section {
            HStack {
                Label("Unlocked · ~\(hoursLeft)h left", systemImage: "lock.open.fill")
                    .font(.mlrScaled(13, weight: .medium))
                    .foregroundStyle(Color.mlrPrimary)
                Spacer()
                Button("Re-lock") {
                    Task { await runOverride("cancel_admin_override", note: "Re-locked.") }
                }
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrDanger)
            }
        }
    }

    private var fieldsSection: some View {
        Section {
            ForEach(Self.fields, id: \.key) { f in
                LabeledContent(f.label) {
                    TextField(f.placeholder, text: Binding(
                        get: { values[f.key] ?? "" },
                        set: { values[f.key] = $0 }))
                        .multilineTextAlignment(.trailing)
                }
            }
            Toggle("Has Apple Cash", isOn: $appleCash).tint(Color.mlrPrimary)
        } header: {
            Text("Member info")
        } footer: {
            Text("Changes their profile fields. Their login email isn't changed here.")
        }
    }

    // MARK: - Data

    private func loadOverride() async {
        struct StatusRow: Decodable {
            let unlockedUntil: Date?
            enum CodingKeys: String, CodingKey { case unlockedUntil = "unlocked_until" }
        }
        if let row: StatusRow = try? await supabase.rpc("admin_override_status").execute().value {
            ready = true
            unlockedUntil = row.unlockedUntil
        } else {
            ready = false
        }
        loading = false
    }

    private func loadProfile() async {
        let keys = (Self.fields.map(\.key) + ["apple_cash"]).joined(separator: ", ")
        struct Row: Decodable {
            let data: [String: AnyJSONValue]
            init(from decoder: Decoder) throws {
                data = try decoder.singleValueContainer().decode([String: AnyJSONValue].self)
            }
        }
        guard let row: Row = try? await supabase
            .from("profiles").select(keys).eq("id", value: member.id.uuidString)
            .single().execute().value
        else { return }
        var v: [String: String] = [:]
        for f in Self.fields { v[f.key] = row.data[f.key]?.stringValue ?? "" }
        values = v
        appleCash = row.data["apple_cash"]?.boolValue ?? false
    }

    private func save() async {
        busy = true; status = nil
        defer { busy = false }
        var patch: [String: AnyJSON] = ["apple_cash": .bool(appleCash)]
        for f in Self.fields {
            patch[f.key] = .string((values[f.key] ?? "").trimmingCharacters(in: .whitespaces))
        }
        struct Params: Encodable { let target: String; let patch: [String: AnyJSON] }
        do {
            try await supabase
                .rpc("admin_set_member_profile", params: Params(target: member.id.uuidString, patch: patch))
                .execute()
            status = "Saved ✓"
            onSaved()
        } catch {
            status = "Couldn't save — is the unlock still active?"
        }
    }

    private func runOverride(_ rpc: String, note: String) async {
        busy = true
        defer { busy = false }
        do {
            try await supabase.rpc(rpc).execute()
            await loadOverride()
            status = note
        } catch {
            status = "Couldn't update the unlock."
        }
    }
}

// MARK: - Minimal JSON value decoder (for the profiles projection)

private struct AnyJSONValue: Decodable {
    let stringValue: String?
    let boolValue: Bool?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { stringValue = s; boolValue = nil }
        else if let b = try? c.decode(Bool.self) { boolValue = b; stringValue = nil }
        else if let i = try? c.decode(Int.self) { stringValue = String(i); boolValue = nil }
        else { stringValue = nil; boolValue = nil }
    }
}
