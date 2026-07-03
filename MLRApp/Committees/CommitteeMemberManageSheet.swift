import SwiftUI

// MARK: - CommitteeMemberManageSheet
//
// Lead/admin controls for a single committee member (migration 0051): promote or
// demote Lead, and assign the area(s) they work in. Saving calls set_committee_lead
// / set_committee_areas only for what actually changed.

struct CommitteeMemberManageSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let committee: Committee
    let member: CommitteeMember
    /// Areas already in use on this committee, offered as quick-add suggestions.
    let suggestedAreas: [String]
    let onSaved: () -> Void

    @State private var isLead: Bool
    @State private var areas: [String]
    @State private var newArea = ""
    @State private var saving = false
    @State private var errorText: String?

    init(committee: Committee, member: CommitteeMember, suggestedAreas: [String], onSaved: @escaping () -> Void) {
        self.committee = committee
        self.member = member
        self.suggestedAreas = suggestedAreas
        self.onSaved = onSaved
        _isLead = State(initialValue: member.role == .lead)
        _areas = State(initialValue: member.areas)
    }

    private var memberName: String { member.profile?.name ?? "Member" }
    private var addableSuggestions: [String] { suggestedAreas.filter { !areas.contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Committee lead", isOn: $isLead)
                        .tint(Color.mlrPrimary)
                } footer: {
                    Text("Leads can approve join requests, manage members, and email the committee.")
                }

                Section("Areas") {
                    if areas.isEmpty {
                        Text("No areas assigned.")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                    ForEach(areas, id: \.self) { area in
                        HStack {
                            Text(area)
                            Spacer()
                            Button {
                                areas.removeAll { $0 == area }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Color.mlrDanger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Add an area", text: $newArea)
                        Button("Add") { addArea(newArea) }
                            .disabled(newArea.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !addableSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggestions").font(.caption).foregroundStyle(Color.mlrTextMuted)
                            ForEach(addableSuggestions, id: \.self) { s in
                                Button { addArea(s) } label: {
                                    Label(s, systemImage: "plus").font(.mlrScaled(13))
                                }
                            }
                        }
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.mlrCaption).foregroundStyle(Color.mlrDanger)
                    }
                }
            }
            .navigationTitle(memberName)
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.mlrPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.fontWeight(.semibold) }
                }
            }
        }
    }

    private func addArea(_ raw: String) {
        let a = raw.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !areas.contains(a) else { return }
        areas.append(a)
        newArea = ""
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            if isLead != (member.role == .lead) {
                try await env.committeeService.setCommitteeLead(
                    committeeId: committee.id, targetUserId: member.userId, isLead: isLead
                )
            }
            if Set(areas) != Set(member.areas) {
                try await env.committeeService.setCommitteeAreas(
                    committeeId: committee.id, targetUserId: member.userId, areas: areas
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorText = "Couldn't save changes. Please try again."
            print("[CommitteeMemberManageSheet] save error: \(error)")
        }
    }
}
