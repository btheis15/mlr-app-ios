import SwiftUI
import UIKit

// MARK: - CommitteeEmailComposer
//
// "Email these members" for a committee (any member or admin, migration 0031).
// Loads the gated recipient roster, enriches each with the member's areas (from
// committee_members.areas) so we can offer a "By Role" filter, then hands off to
// the native Mail composer. Mirrors the web EmailMembersComposer.

struct CommitteeEmailComposer: View {
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    /// Loaded committee members — used to enrich recipients with their areas.
    var members: [CommitteeMember] = []
    /// Recipients supplied directly (e.g. from the roster). When set, we use these
    /// instead of loading committee_members — areas come from each person's roles,
    /// so the "By Role" filter works off the roster.
    var presetRecipients: [Recipient]? = nil

    enum Mode: String, CaseIterable { case everyone, byRole, pick }

    struct Recipient: Identifiable, Equatable {
        let id: UUID
        let name: String
        let email: String
        let areas: [String]
    }

    @State private var recipients: [Recipient] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var mode: Mode = .everyone
    @State private var selectedArea: String?
    @State private var selectedIds: Set<UUID> = []
    @State private var query = ""
    @State private var subject = ""
    @State private var showMail = false
    @State private var copied = false

    private var hasRoles: Bool { recipients.contains { !$0.areas.isEmpty } }

    private var areaOptions: [String] {
        Array(Set(recipients.flatMap(\.areas))).sorted()
    }

    private var audience: [Recipient] {
        switch mode {
        case .everyone: return recipients
        case .byRole:
            guard let area = selectedArea else { return [] }
            return recipients.filter { $0.areas.contains(area) }
        case .pick:
            return recipients.filter { selectedIds.contains($0.id) }
        }
    }

    private var audienceEmails: [String] {
        Array(Set(audience.map(\.email))).sorted()
    }

    private var shownForPick: [Recipient] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return recipients }
        return recipients.filter { $0.name.lowercased().contains(q) || $0.email.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let loadError {
                    Text(loadError).font(.mlrCaption).foregroundStyle(Color.mlrDanger).padding()
                } else if recipients.isEmpty {
                    Text("No one to email here yet.")
                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted).padding()
                } else {
                    content
                }
            }
            .navigationTitle("Email \(committee.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await load() }
            .sheet(isPresented: $showMail) {
                MailComposeView(recipients: audienceEmails, subject: subject)
                    .ignoresSafeArea()
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Opens your email app with the people below in the To field — write and send it from there. Nothing is sent from the app.")
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)

                // Mode picker
                Picker("Mode", selection: $mode) {
                    Text("Everyone (\(recipients.count))").tag(Mode.everyone)
                    if hasRoles { Text("By Role").tag(Mode.byRole) }
                    Text("Pick").tag(Mode.pick)
                }
                .pickerStyle(.segmented)

                if mode == .byRole {
                    VStack(spacing: 6) {
                        ForEach(areaOptions, id: \.self) { area in
                            let count = recipients.filter { $0.areas.contains(area) }.count
                            Button {
                                selectedArea = selectedArea == area ? nil : area
                            } label: {
                                HStack {
                                    Text(area)
                                        .font(.mlrScaled(14, weight: .medium))
                                        .foregroundStyle(selectedArea == area ? Color.mlrPrimary : Color.mlrText)
                                    Spacer()
                                    Text("\(selectedArea == area ? "✓ " : "")\(count) \(count == 1 ? "person" : "people")")
                                        .font(.caption)
                                        .foregroundStyle(selectedArea == area ? Color.mlrPrimary : Color.mlrTextMuted)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(selectedArea == area ? Color.mlrPrimary.opacity(0.1) : Color.mlrCard)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if mode == .pick {
                    TextField("Search name or email…", text: $query)
                        .fieldStyle()
                    VStack(spacing: 0) {
                        ForEach(shownForPick) { r in
                            Button {
                                if selectedIds.contains(r.id) { selectedIds.remove(r.id) }
                                else { selectedIds.insert(r.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedIds.contains(r.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selectedIds.contains(r.id) ? Color.mlrPrimary : Color.mlrTextSubtle)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.name).font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrText)
                                        Text(r.email).font(.caption).foregroundStyle(Color.mlrTextMuted)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color.mlrCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                TextField("Subject (optional)", text: $subject)
                    .fieldStyle()

                Text(audienceLabel)
                    .font(.mlrCaption)
                    .foregroundStyle(Color.mlrTextMuted)

                Button {
                    if MailComposeView.canSend { showMail = true } else { copyAddresses() }
                } label: {
                    Text("✉️ Open email")
                        .primaryButton()
                }
                .disabled(audienceEmails.isEmpty)
                .opacity(audienceEmails.isEmpty ? 0.5 : 1)

                Button {
                    copyAddresses()
                } label: {
                    Text(copied ? "Copied ✓" : "Copy addresses")
                        .font(.mlrScaled(14, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.mlrPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(audienceEmails.isEmpty)
            }
            .padding(20)
        }
    }

    private var audienceLabel: String {
        if audience.isEmpty {
            return mode == .byRole ? "Pick a role above to choose who to email." : "No one selected yet."
        }
        let n = audienceEmails.count
        return "Emailing \(n) \(n == 1 ? "person" : "people")."
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Roster-supplied recipients: use them directly (membership lives in the
        // roster now, not committee_members).
        if let presetRecipients {
            recipients = presetRecipients
            return
        }
        let areaByUser = Dictionary(members.map { ($0.userId, $0.areas) }, uniquingKeysWith: { a, _ in a })
        do {
            let rows = try await env.committeeService.fetchCommitteeRecipients(committeeId: committee.id)
            recipients = rows.map { r in
                Recipient(id: r.id, name: r.name, email: r.email, areas: areaByUser[r.id] ?? [])
            }
        } catch {
            loadError = "Couldn't load recipients."
            print("[CommitteeEmailComposer] load error: \(error)")
        }
    }

    private func copyAddresses() {
        UIPasteboard.general.string = audienceEmails.joined(separator: ", ")
        copied = true
    }

    @Environment(AppEnvironment.self) private var env
}
