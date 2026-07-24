import SwiftUI

// MARK: - ChatPollCard (migration 0149)
//
// An inline "quick poll" bubble rendered in the message timeline (sorted by
// createdAt alongside real messages). Tap an option to vote; single-select
// replaces your pick, multi-select toggles. Anonymous polls show counts only;
// attributed polls let you see who voted. The creator or an admin can close
// (freeze) or delete it. Mirrors the web ChatPollCard.

struct ChatPollCard: View {
    let poll: ChatPoll
    /// Full-replace my votes (option ids + optional write-in text).
    let onSetVotes: ([UUID], String?) async -> Void
    let onClose: () async -> Void
    let onDelete: () async -> Void
    let fetchVoters: () async -> [ChatPollVoter]

    @Environment(AppEnvironment.self) private var env

    @State private var selected: Set<UUID> = []
    @State private var otherText: String = ""
    @State private var busy = false
    @State private var showVoters = false

    private var canManage: Bool {
        env.isAdmin || (poll.createdByMe)
    }
    private var isClosed: Bool { poll.isClosed }
    private var maxCount: Int { max(1, poll.options.map(\.voteCount).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 6) {
                ForEach(poll.sortedOptions) { option in
                    optionRow(option)
                }
            }
            footer
        }
        .padding(14)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.mlrPrimary.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { selected = Set(poll.myOptionIds); otherText = poll.myOtherText ?? "" }
        .onChange(of: poll.myOptionIds) { _, new in selected = Set(new) }
        .sheet(isPresented: $showVoters) {
            ChatPollVotersSheet(poll: poll, fetchVoters: fetchVoters)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(poll.question)
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(subtitleText)
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrTextMuted)
            }
            Spacer(minLength: 4)
            if canManage {
                Menu {
                    if !isClosed {
                        Button { run { await onClose() } } label: { Label("Close poll", systemImage: "lock") }
                    }
                    Button(role: .destructive) { run { await onDelete() } } label: {
                        Label("Delete poll", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrTextSubtle)
                }
            }
        }
    }

    private var subtitleText: String {
        var bits: [String] = []
        bits.append(poll.allowMultiple ? "Pick any" : "Pick one")
        if poll.anonymous { bits.append("anonymous") }
        if isClosed { bits.append("closed") }
        return bits.joined(separator: " · ")
    }

    // MARK: Option row

    @ViewBuilder
    private func optionRow(_ option: ChatPollOption) -> some View {
        let isMine = selected.contains(option.id)
        let fraction = Double(option.voteCount) / Double(maxCount)
        Button {
            guard !isClosed, !busy else { return }
            toggle(option)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: isMine ? (poll.allowMultiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                                             : (poll.allowMultiple ? "square" : "circle"))
                        .font(.mlrScaled(14))
                        .foregroundStyle(isMine ? Color.mlrPrimary : Color.mlrTextSubtle)
                    Text(option.isOther ? (option.label.isEmpty ? "Other" : option.label) : option.label)
                        .font(.mlrScaled(14, weight: isMine ? .semibold : .regular))
                        .foregroundStyle(Color.mlrText)
                    Spacer(minLength: 4)
                    Text("\(option.voteCount)")
                        .font(.mlrScaled(12, weight: .medium))
                        .foregroundStyle(Color.mlrTextMuted)
                        .contentTransition(.numericText())
                }
                // Proportional tally bar.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.mlrPrimary.opacity(0.08))
                        Capsule().fill(Color.mlrPrimary.opacity(isMine ? 0.35 : 0.18))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.mlrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isClosed || busy)

        // Inline write-in for the "Other" option once it's selected.
        if option.isOther && isMine && !isClosed {
            HStack(spacing: 8) {
                TextField("Add your answer…", text: $otherText)
                    .font(.mlrScaled(13))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitVotes() }
                Button("Save") { commitVotes() }
                    .font(.mlrScaled(12, weight: .semibold))
                    .disabled(otherText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 26)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(poll.respondentCount) \(poll.respondentCount == 1 ? "response" : "responses")")
                .font(.mlrScaled(11, weight: .medium))
                .foregroundStyle(Color.mlrTextMuted)
                .contentTransition(.numericText())
            Spacer()
            if !poll.anonymous && poll.respondentCount > 0 {
                Button { showVoters = true } label: {
                    Label("Who voted", systemImage: "person.2")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Voting

    private func toggle(_ option: ChatPollOption) {
        if poll.allowMultiple {
            if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
        } else {
            selected = selected.contains(option.id) ? [] : [option.id]
        }
        // For the "Other" option we wait for the write-in Save; otherwise commit now.
        if option.isOther && selected.contains(option.id) { return }
        commitVotes()
    }

    private func commitVotes() {
        let ids = Array(selected)
        let other = otherText.trimmingCharacters(in: .whitespaces)
        run { await onSetVotes(ids, other.isEmpty ? nil : other) }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { await work(); busy = false }
    }
}

// MARK: - Voters sheet

private struct ChatPollVotersSheet: View {
    let poll: ChatPoll
    let fetchVoters: () async -> [ChatPollVoter]

    @Environment(\.dismiss) private var dismiss
    @State private var voters: [ChatPollVoter] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                ForEach(poll.sortedOptions) { option in
                    let people = voters.filter { $0.optionId == option.id }
                    if !people.isEmpty {
                        Section(option.isOther ? "Other" : option.label) {
                            ForEach(people) { v in
                                HStack(spacing: 10) {
                                    AvatarView(url: v.avatarUrl, size: .small)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(v.name).font(.mlrScaled(15, weight: .medium))
                                        if let t = v.otherText, !t.isEmpty {
                                            Text(t).font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if voters.isEmpty { Text("No votes yet.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Who voted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { voters = await fetchVoters(); loading = false }
        }
    }
}

// MARK: - CreateChatPollSheet

struct CreateChatPollSheet: View {
    let scope: ChatPollScope
    let onCreated: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var allowMultiple = false
    @State private var anonymous = false
    @State private var allowOther = false
    @State private var creating = false
    @State private var errorText: String?

    private var trimmedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && trimmedOptions.count >= 2 && !creating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("What's it for?", text: $question, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in
                        TextField("Option \(i + 1)", text: $options[i])
                    }
                    if options.count < 10 {
                        Button { options.append("") } label: {
                            Label("Add option", systemImage: "plus.circle")
                        }
                    }
                }
                Section {
                    Toggle("Allow multiple picks", isOn: $allowMultiple)
                    Toggle("Anonymous (counts only)", isOn: $anonymous)
                    Toggle("Allow a write-in \"Other\"", isOn: $allowOther)
                }
                if let errorText {
                    Section { Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                }
            }
            .navigationTitle("New poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Posting…" : "Post") { Task { await create() } }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private func create() async {
        creating = true; errorText = nil
        defer { creating = false }
        do {
            _ = try await env.chatPollsService.createPoll(
                scope: scope,
                question: question.trimmingCharacters(in: .whitespaces),
                options: trimmedOptions,
                allowMultiple: allowMultiple,
                anonymous: anonymous,
                allowOther: allowOther
            )
            onCreated()
            dismiss()
        } catch {
            errorText = "Couldn't post the poll. Try again."
        }
    }
}
