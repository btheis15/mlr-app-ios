import SwiftUI

// MARK: - PollsView
// Full list of all polls — open first, then closed. Any signed-in member can
// create a poll; creators and admins can close or delete.
// Mirrors web /polls page (migration 0084).

struct PollsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showCreate = false

    private var openPolls:   [Poll] { env.pollsService.polls.filter {  $0.isOpen } }
    private var closedPolls: [Poll] { env.pollsService.polls.filter { !$0.isOpen } }

    var body: some View {
        Group {
            if env.pollsService.isLoading && env.pollsService.polls.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if env.pollsService.polls.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(openPolls)   { poll in PollCard(poll: poll) }
                        if !closedPolls.isEmpty {
                            SectionLabel(text: "Closed polls")
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                            ForEach(closedPolls) { poll in PollCard(poll: poll) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Polls")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if env.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .refreshable {
            await env.pollsService.fetchPolls(userId: env.currentProfile?.id)
        }
        .task {
            await env.pollsService.fetchPolls(userId: env.currentProfile?.id)
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                PollCreatorSheet {
                    Task { await env.pollsService.fetchPolls(userId: env.currentProfile?.id) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis.ascending")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.mlrTextSubtle)
            Text("No polls yet")
                .font(.headline)
                .foregroundStyle(Color.mlrTextMuted)
            if env.isSignedIn {
                Button("Create the first poll") { showCreate = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - PollCard

struct PollCard: View {
    @Environment(AppEnvironment.self) private var env
    let poll: Poll

    private var canManage: Bool {
        env.isAdmin || poll.createdBy == env.currentProfile?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question + status badge
            HStack(alignment: .top, spacing: 10) {
                Text(poll.question)
                    .font(.mlrScaled(16, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                statusBadge
            }

            // Option rows
            VStack(spacing: 6) {
                ForEach(poll.options) { option in
                    PollOptionRow(option: option, poll: poll) {
                        guard env.isSignedIn else { env.authService.promptSignIn(); return }
                        Task { try? await env.pollsService.vote(pollId: poll.id, optionId: option.id) }
                    }
                }
            }

            // Footer: vote count + manage actions
            HStack {
                Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s")")
                    .contentTransition(.numericText())
                    .animation(.default, value: poll.totalVotes)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextSubtle)
                Spacer()
                if canManage {
                    if poll.isOpen {
                        Button("Close poll") {
                            Task { try? await env.pollsService.closePoll(pollId: poll.id) }
                        }
                        .font(.caption)
                        .foregroundStyle(Color.mlrTextMuted)
                    }
                    Button("Delete") {
                        Task { try? await env.pollsService.deletePoll(pollId: poll.id) }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.mlrDanger)
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    @ViewBuilder
    private var statusBadge: some View {
        if poll.isClosed {
            badge("Closed", color: Color.mlrTextSubtle)
        } else if let days = poll.closesInDays() {
            badge(days == 0 ? "Closes today" : "Closes in \(days)d", color: Color.mlrWarning)
        } else {
            badge("Open", color: Color.mlrSuccess)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - PollOptionRow

private struct PollOptionRow: View {
    let option: PollOption
    let poll: Poll
    let onVote: () -> Void

    private var isVoted:  Bool   { poll.myVoteOptionId == option.id }
    private var percent:  Double { poll.votePercent(for: option) }

    var body: some View {
        Button(action: { if poll.isOpen { onVote() } }) {
            HStack(spacing: 8) {
                Image(systemName: isVoted ? "checkmark.circle.fill" : "circle")
                    .font(.mlrScaled(16))
                    .foregroundStyle(isVoted ? Color.mlrPrimary : Color.mlrTextSubtle)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(option.label)
                            .font(.mlrScaled(14, weight: isVoted ? .semibold : .regular))
                            .foregroundStyle(isVoted ? Color.mlrPrimary : Color.mlrText)
                        Spacer()
                        Text("\(Int(percent * 100))%")
                            .font(.mlrScaled(12, weight: .medium))
                            .foregroundStyle(Color.mlrTextMuted)
                            .contentTransition(.numericText())   // rolls as votes land (#347)
                            .animation(.default, value: percent)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.mlrCard)
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isVoted ? Color.mlrPrimary : Color.mlrTextSubtle.opacity(0.6))
                                .frame(width: geo.size.width * percent, height: 4)
                                .animation(.easeInOut(duration: 0.3), value: percent)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(poll.isOpen ? 1 : 0.75)
    }
}

// MARK: - PollCreatorSheet

struct PollCreatorSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var hasClosingDate = false
    @State private var closesOnDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var isSaving = false
    @State private var saveError: String? = nil

    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
    }

    var body: some View {
        Form {
            Section("Question") {
                TextField("What would you like to ask?", text: $question, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                ForEach(options.indices, id: \.self) { idx in
                    HStack {
                        TextField("Option \(idx + 1)", text: $options[idx])
                        if options.count > 2 {
                            Button {
                                options.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Color.mlrDanger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if options.count < 10 {
                    Button { options.append("") } label: {
                        Label("Add option", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Options (2–10)")
            }

            Section {
                Toggle("Set a closing date", isOn: $hasClosingDate)
                if hasClosingDate {
                    DatePicker(
                        "Closes on",
                        selection: $closesOnDate,
                        in: Calendar.current.date(byAdding: .day, value: 1, to: Date())!...,
                        displayedComponents: .date
                    )
                }
            } header: {
                Text("Optional")
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13))
                }
            }
        }
        .navigationTitle("New Poll")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving { ProgressView() }
                else {
                    Button("Create") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        isSaving = true; saveError = nil
        defer { isSaving = false }
        let q    = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let isoFmt = DateFormatter(); isoFmt.dateFormat = "yyyy-MM-dd"
        let closesOn: String? = hasClosingDate ? isoFmt.string(from: closesOnDate) : nil
        do {
            try await env.pollsService.createPoll(question: q, options: opts, closesOn: closesOn)
            onCreated()
            dismiss()
        } catch {
            saveError = "Couldn't create poll. Check your connection and try again."
        }
    }
}

// MARK: - PollHomeCard
// Shown on the Home screen when at least one poll is open.
// Self-hides when there are no open polls; loads data lazily on first appear.

struct PollHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    private var newestOpen: Poll? { env.pollsService.polls.first { $0.isOpen } }

    var body: some View {
        if let poll = newestOpen {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(destination: PollsView()) {
                    HStack {
                        Label("Polls", systemImage: "chart.bar.xaxis.ascending")
                            .font(.mlrScaled(13, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                        Spacer()
                        Text("See all")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrTextMuted)
                        Image(systemName: "chevron.right")
                            .font(.mlrScaled(10, weight: .semibold))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                .buttonStyle(.plain)

                PollCard(poll: poll)
            }
            .task {
                if env.pollsService.polls.isEmpty {
                    await env.pollsService.fetchPolls(userId: env.currentProfile?.id)
                }
            }
        }
    }
}
