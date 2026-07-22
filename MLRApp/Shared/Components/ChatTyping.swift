import SwiftUI
import Supabase

// MARK: - Chat typing indicators (#361)
//
// A live "X is typing…" row above the chat composer. Rides its OWN Supabase
// Realtime *broadcast* channel `typing:<roomKey>`, SEPARATE from the message
// subscription so it can never disrupt delivery. Ephemeral — nothing persisted,
// no table/RPC. Mirrors the web app's useTypingChannel (lib/hooks.ts):
//   • notifyTyping() is throttled to one ping / 2.5s, only while text is non-empty
//   • each typer self-clears ~4.5s after their last keystroke
//   • own broadcasts are never received (receiveOwnBroadcasts defaults false)

@Observable
@MainActor
final class ChatTypingChannel {
    /// Display names currently typing (excludes me).
    private(set) var typers: [String] = []

    private var channel: RealtimeChannelV2?
    private var uid: UUID?
    private var myName = ""
    private var lastSent = Date.distantPast
    private var receiveTask: Task<Void, Never>?
    private var namesByUid: [String: String] = [:]
    private var clearTasks: [String: Task<Void, Never>] = [:]

    /// `roomKey` = "committee:<slug>:<area>" or "house:<slug>".
    func start(roomKey: String, uid: UUID, name: String) {
        guard channel == nil else { return }
        self.uid = uid
        self.myName = name
        let chan = supabase.channel("typing:\(roomKey)")
        channel = chan
        receiveTask = Task { [weak self] in
            let stream = chan.broadcastStream(event: "typing")
            await chan.subscribe()
            for await payload in stream {
                guard let self else { break }
                guard let who = payload["uid"]?.stringValue, who != uid.uuidString else { continue }
                let name = payload["name"]?.stringValue ?? "Someone"
                self.namesByUid[who] = name
                self.recompute()
                self.scheduleClear(who)
            }
        }
    }

    func notifyTyping() {
        guard let uid, let channel else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 2.5 else { return }   // throttle
        lastSent = now
        let payload: JSONObject = ["uid": .string(uid.uuidString), "name": .string(myName)]
        Task { await channel.broadcast(event: "typing", message: payload) }
    }

    func stop() {
        receiveTask?.cancel(); receiveTask = nil
        clearTasks.values.forEach { $0.cancel() }
        clearTasks.removeAll()
        namesByUid.removeAll()
        typers = []
        if let channel { Task { await supabase.removeChannel(channel) } }
        channel = nil
    }

    private func scheduleClear(_ who: String) {
        clearTasks[who]?.cancel()
        clearTasks[who] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard let self, !Task.isCancelled else { return }
            self.namesByUid[who] = nil
            self.clearTasks[who] = nil
            self.recompute()
        }
    }

    private func recompute() {
        typers = Array(namesByUid.values)
    }
}

// MARK: - Typing indicator row

/// The "… is typing" row shown above the composer. Renders nothing when idle.
struct TypingIndicator: View {
    let names: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private var label: String? {
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "Several people are typing"
        }
    }

    var body: some View {
        if let label {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Color.mlrTextMuted.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.6 : (animate ? 1 : 0.3))
                            .animation(reduceMotion ? nil :
                                .easeInOut(duration: 0.9).repeatForever().delay(Double(i) * 0.15),
                                value: animate)
                    }
                }
                Text("\(label)…")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 3)
            .accessibilityElement()
            .accessibilityLabel(label)
            .onAppear { animate = true }
        }
    }
}
