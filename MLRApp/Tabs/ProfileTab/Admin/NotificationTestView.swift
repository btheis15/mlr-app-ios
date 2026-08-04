import SwiftUI

// MARK: - NotificationTestView
//
// Admin → Notification Test (migrations 0156-0157). Two related tools:
// 1. Send a one-off test notification (Activity tab + phone push) to ONE
//    specific member — for "I'm not getting notifications" support requests,
//    so an admin can check the pipeline for that one person without alerting
//    anyone else.
// 2. A "Notifications confirmed" checklist — once an admin has actually
//    watched a test land on someone's phone, they check the box next to that
//    person's name. Not wired to the send tool above; any admin can check/
//    uncheck anyone. Mirrors web's NotificationTestView.

struct NotificationTestView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var roster: [NotificationTestMember] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var pickerOpen = false
    @State private var target: NotificationTestMember?
    @State private var testTitle = ""
    @State private var testBody = ""
    @State private var isSending = false
    @State private var sendResult: String?

    @State private var query = ""
    @State private var busyIds: Set<UUID> = []

    private var shownRoster: [NotificationTestMember] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return roster }
        return roster.filter { $0.name.lowercased().contains(q) }
    }

    private var confirmedCount: Int { roster.filter(\.confirmed).count }

    var body: some View {
        List {
            Section {
                Button {
                    pickerOpen = true
                } label: {
                    HStack {
                        Text(target?.name ?? "Choose a member")
                            .foregroundStyle(target == nil ? Color.mlrTextMuted : Color.mlrText)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                .buttonStyle(.pressable)

                if target != nil {
                    TextField("Title (optional)", text: $testTitle)
                    TextField("Body (optional)", text: $testBody, axis: .vertical)
                        .lineLimit(1...3)

                    Button {
                        Task { await sendTest() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSending { ProgressView() } else { Text("Send test notification") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.pressable)
                    .disabled(isSending)
                }

                if let sendResult {
                    Text(sendResult)
                        .font(.mlrScaled(13))
                        .foregroundStyle(sendResult.hasPrefix("Sent") ? Color.mlrSuccess : Color.mlrDanger)
                }
            } header: {
                Text("Send a test")
            } footer: {
                Text("Pings that one person's Activity tab + phone push, bypassing their notification-category picks — for checking the pipeline reaches their device.")
            }

            Section {
                if isLoading && roster.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in SkeletonShape(height: 40, cornerRadius: 8).listRowSeparator(.hidden) }
                } else if let loadError, roster.isEmpty {
                    Label(loadError, systemImage: "xmark.circle").foregroundStyle(Color.mlrWarning)
                } else {
                    ForEach(shownRoster) { member in
                        confirmRow(member)
                    }
                }
            } header: {
                Text("Notifications confirmed")
            } footer: {
                Text("\(confirmedCount) of \(roster.count) confirmed. Check a name once you've personally watched a test notification arrive on their phone — this is a manual record, not tied to the sender above.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search members")
        .navigationTitle("Notification Test")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $pickerOpen) {
            NotificationTestMemberPicker(members: roster) { picked in
                target = picked
                sendResult = nil
            }
        }
    }

    private func confirmRow(_ member: NotificationTestMember) -> some View {
        Button {
            Task { await toggleConfirmed(member) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: member.avatarUrl, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .font(.mlrScaled(15, weight: .medium))
                        .foregroundStyle(Color.mlrText)
                    if member.confirmed {
                        let when = member.confirmedAt.map { MLRFormat.relativeTime($0) }
                        let who = member.confirmedByName
                        let subtitle = [who.map { "by \($0)" }, when].compactMap { $0 }.joined(separator: " · ")
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.mlrScaled(12))
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                }
                Spacer()
                if busyIds.contains(member.id) {
                    ProgressView()
                } else {
                    Image(systemName: member.confirmed ? "checkmark.circle.fill" : "circle")
                        .font(.mlrScaled(20))
                        .foregroundStyle(member.confirmed ? Color.mlrSuccess : Color.mlrTextSubtle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(busyIds.contains(member.id))
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        roster = await env.notificationsService.fetchNotificationTestRoster()
    }

    private func sendTest() async {
        guard let target else { return }
        isSending = true
        sendResult = nil
        defer { isSending = false }
        do {
            try await env.notificationsService.sendTestNotification(
                userId: target.id,
                title: testTitle.isEmpty ? nil : testTitle,
                body: testBody.isEmpty ? nil : testBody
            )
            sendResult = "Sent to \(target.name)."
        } catch {
            sendResult = "Couldn't send. Try again."
            print("[NotificationTestView] sendTest error: \(error)")
        }
    }

    private func toggleConfirmed(_ member: NotificationTestMember) async {
        let newValue = !member.confirmed
        busyIds.insert(member.id)
        defer { busyIds.remove(member.id) }
        do {
            try await env.notificationsService.setNotificationTestConfirmed(userId: member.id, value: newValue)
            if let idx = roster.firstIndex(where: { $0.id == member.id }) {
                roster[idx].confirmed = newValue
                roster[idx].confirmedAt = newValue ? .now : nil
                roster[idx].confirmedByName = newValue ? (env.currentProfile?.displayName ?? "You") : nil
            }
        } catch {
            print("[NotificationTestView] toggleConfirmed error: \(error)")
        }
    }
}

// MARK: - Member picker sheet

private struct NotificationTestMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    let members: [NotificationTestMember]
    let onPick: (NotificationTestMember) -> Void

    @State private var query = ""

    private var shown: [NotificationTestMember] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { member in
                Button {
                    onPick(member)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: member.avatarUrl, size: .small)
                        Text(member.name).foregroundStyle(Color.mlrText)
                    }
                }
                .buttonStyle(.pressable)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search members")
            .navigationTitle("Choose a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
