import SwiftUI
import MLRCore

// MARK: - Chats (watch)
// Conversation list (your House + committees you're in) → read-only message
// history. Reply is a fast-follow.

struct WatchChatsListView: View {
    @Environment(WatchSessionReceiver.self) private var session

    @State private var conversations: [WatchConversation] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !session.isAuthed {
                syncHint
            } else if conversations.isEmpty {
                Text(loaded ? "No chats yet." : "Loading…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conversations) { convo in
                    NavigationLink {
                        WatchChatThreadView(conversation: convo)
                    } label: {
                        HStack(spacing: 8) {
                            Text(convo.emoji)
                            Text(convo.title)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .task(id: session.isAuthed) {
            guard session.isAuthed else { return }
            conversations = await WatchData.conversations()
            loaded = true
        }
    }

    private var syncHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Open the MLR app on your iPhone to sync.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

struct WatchChatThreadView: View {
    let conversation: WatchConversation

    @State private var messages: [WatchChatMessage] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if messages.isEmpty {
                    Text(loaded ? "No messages yet." : "Loading…")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(messages) { msg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(msg.authorName)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Text(msg.text)
                                .font(.system(size: 15, design: .rounded))
                        }
                        .id(msg.id)
                        .listRowInsets(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }

                // Reply — tapping the field brings up watch input (Dictation /
                // Scribble / emoji). Sends to the General channel.
                Section {
                    HStack(spacing: 6) {
                        TextField("Reply", text: $draft)
                            .font(.system(size: 15, design: .rounded))
                            .submitLabel(.send)
                            .onSubmit { Task { await send(proxy: proxy) } }
                        Button {
                            Task { await send(proxy: proxy) }
                        } label: {
                            Image(systemName: sending ? "clock" : "arrow.up.circle.fill")
                                .font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? Color.green : .secondary)
                        .disabled(!canSend)
                    }
                }
            }
            .navigationTitle(conversation.title)
            .task {
                messages = await WatchData.messages(for: conversation)
                loaded = true
                scrollToLast(proxy)
            }
            .onChange(of: messages.count) { _, _ in scrollToLast(proxy) }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let last = messages.last?.id else { return }
        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
    }

    private func send(proxy: ScrollViewProxy) async {
        guard canSend else { return }
        let text = draft
        sending = true
        defer { sending = false }
        let ok = await WatchData.sendMessage(text, to: conversation)
        if ok {
            draft = ""
            messages = await WatchData.messages(for: conversation)
        }
    }
}
