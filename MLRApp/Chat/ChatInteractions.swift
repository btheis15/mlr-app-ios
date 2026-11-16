import SwiftUI

// MARK: - ChatInteractions
//
// The shared "native messenger" behaviour for all three chat rooms (committee,
// house, event). The rooms stay separate views; each behaviour is built ONCE
// here and applied in all three so they feel identical:
//   • ChatMessageRow  — group spacing, avatar + name once, day separator, "New"
//                       divider, swipe-to-reply, double-tap tapback, tap-for-time,
//                       sending / "Not delivered" state with Retry + Delete
//   • ChatGrouping    — consecutive-author grouping + day labels
//   • ChatReactionPills, ChatPendingAttachments, ChatJumpPill
//   • ChatDraftStore / .chatDraftPersistence — per-room unsent text
//   • ChatReadMarker  — device-local "last seen" marker for the "New" divider
//   • .chatScrollBehavior — bottom anchor, interactive keyboard dismiss

// MARK: - Motion helper

/// `withAnimation` that degrades to an instant change under Reduce Motion.
func chatWithAnimation(_ animation: Animation = MLRMotion.spring, _ body: () -> Void) {
    if MLRMotion.reduceMotion { body() } else { withAnimation(animation, body) }
}

// MARK: - Delivery state (optimistic sends)

enum ChatDelivery: Equatable {
    case sending
    case failed
}

/// Everything needed to (re)send a message that has not been confirmed yet.
struct ChatOutgoing {
    var text: String
    var replyToId: UUID?
    var mentionedIds: [UUID]
    var attachments: [ChatAttachment]
}

/// One unconfirmed outgoing message, keyed by its temp bubble id.
struct ChatOutboxEntry {
    var delivery: ChatDelivery
    var payload: ChatOutgoing
    /// 0...1 across the attachments (completed / total).
    var progress: Double = 0
}

// MARK: - Grouping + day labels

struct ChatGroupItem {
    let id: String
    /// nil for non-message entries (polls) — they never join a group.
    let authorId: UUID?
    let date: Date
}

struct ChatRowMeta {
    var startsGroup = true
    var endsGroup = true
    var dayLabel: String?
    var isFirstUnread = false
}

enum ChatGrouping {
    /// Consecutive messages from one person within this window group tightly.
    static let window: TimeInterval = 5 * 60

    static func meta(for items: [ChatGroupItem], firstUnreadId: String? = nil) -> [String: ChatRowMeta] {
        let cal = Calendar.current
        var starts = [Bool](repeating: true, count: items.count)
        var out: [String: ChatRowMeta] = [:]
        out.reserveCapacity(items.count)
        for i in items.indices {
            let cur = items[i]
            var meta = ChatRowMeta()
            var newDay = true
            if i > 0 {
                let prev = items[i - 1]
                newDay = !cal.isDate(prev.date, inSameDayAs: cur.date)
                let sameAuthor = prev.authorId != nil && prev.authorId == cur.authorId
                starts[i] = newDay || !sameAuthor || cur.date.timeIntervalSince(prev.date) > window
            }
            if cur.id == firstUnreadId { starts[i] = true; meta.isFirstUnread = true }
            if newDay { meta.dayLabel = dayLabel(cur.date) }
            meta.startsGroup = starts[i]
            out[cur.id] = meta
        }
        for i in items.indices {
            out[items[i].id]?.endsGroup = (i == items.count - 1) || starts[i + 1]
        }
        return out
    }

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Device-local read marker ("New" divider)
//
// The rooms don't expose their server last-read time to the views, so the
// divider uses a marker kept on this device: the moment the room was last
// closed. Messages from others after it get a "New" divider on the next open.

enum ChatReadMarker {
    private static func key(_ room: String, _ user: UUID) -> String {
        "chat.lastSeen.\(room).\(user.uuidString)"
    }

    static func lastSeen(room: String, user: UUID) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(room, user))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func markSeen(room: String, user: UUID, at date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key(room, user))
    }

    /// First message from someone else newer than `lastSeen` (nil on a first-ever open).
    static func firstUnreadId(in items: [ChatGroupItem], lastSeen: Date?, me: UUID?) -> String? {
        guard let lastSeen else { return nil }
        return items.first { $0.authorId != nil && $0.authorId != me && $0.date > lastSeen }?.id
    }
}

// MARK: - Drafts

enum ChatDraftStore {
    private static func key(_ room: String, _ user: UUID) -> String {
        "chat.draft.\(room).\(user.uuidString)"
    }

    static func load(room: String, user: UUID) -> String {
        UserDefaults.standard.string(forKey: key(room, user)) ?? ""
    }

    static func save(_ text: String, room: String, user: UUID) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key(room, user))
        } else {
            UserDefaults.standard.set(text, forKey: key(room, user))
        }
    }
}

private struct ChatDraftModifier: ViewModifier {
    @Binding var text: String
    let roomKey: String
    let userId: UUID?
    /// True while editing a message (the field then holds that message, not a draft).
    let paused: Bool

    func body(content: Content) -> some View {
        content
            .task(id: userId) {
                guard let userId, !paused, text.isEmpty else { return }
                let saved = ChatDraftStore.load(room: roomKey, user: userId)
                if !saved.isEmpty { text = saved }
            }
            .onChange(of: text) { _, new in
                guard let userId, !paused else { return }
                ChatDraftStore.save(new, room: roomKey, user: userId)
            }
    }
}

extension View {
    /// Persist the unsent composer text per room + user; restores on reopen,
    /// clears when the text is cleared (send). Pass `userId: nil` to never
    /// touch storage (preview mode).
    func chatDraftPersistence(text: Binding<String>, roomKey: String, userId: UUID?, paused: Bool = false) -> some View {
        modifier(ChatDraftModifier(text: text, roomKey: roomKey, userId: userId, paused: paused))
    }

    /// Chat scroll feel: open pinned to the bottom, stay pinned when the keyboard
    /// opens, dismiss the keyboard interactively, and report whether the user is
    /// near the bottom.
    func chatScrollBehavior(atBottom: Binding<Bool>) -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
            } action: { _, distanceFromBottom in
                let near = distanceFromBottom < 80
                if atBottom.wrappedValue != near { atBottom.wrappedValue = near }
            }
    }

    /// The jump-to-bottom pill with an unread count.
    func chatJumpPill(visible: Bool, unread: Int, action: @escaping () -> Void) -> some View {
        overlay(alignment: .bottom) {
            if visible {
                ChatJumpPill(unread: unread, action: action)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: visible)
    }

    /// Bubble fill with a small "tail" corner on the last bubble of a group.
    func chatBubbleBackground(isOwn: Bool, tail: Bool) -> some View {
        let small: CGFloat = 4, big: CGFloat = 20
        let shape = UnevenRoundedRectangle(
                topLeadingRadius: big,
                bottomLeadingRadius: (!isOwn && tail) ? small : big,
                bottomTrailingRadius: (isOwn && tail) ? small : big,
                topTrailingRadius: big, style: .continuous)
        return background(isOwn ? Color.mlrPrimary : Color.mlrCard, in: shape)
            .overlay { if !isOwn { shape.strokeBorder(Color.mlrBorder, lineWidth: 1) } }
    }
}

// MARK: - Jump pill

struct ChatJumpPill: View {
    let unread: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if unread > 0 {
                    Text("\(unread)").contentTransition(.numericText())
                    Text(unread == 1 ? "new message" : "new messages")
                } else {
                    Text("New messages")
                }
            }
            .font(.mlrScaled(12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.mlrPrimary).clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: unread)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Separators

struct ChatDaySeparator: View {
    let label: String
    var body: some View {
        Eyebrow(label, color: .mlrTextMuted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.mlrCard, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mlrBorder, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ChatNewDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.mlrPrimary.opacity(0.35)).frame(height: 1)
            Text("New")
                .font(.mlrScaled(11, weight: .bold))
                .foregroundStyle(Color.mlrPrimary)
            Rectangle().fill(Color.mlrPrimary.opacity(0.35)).frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12).padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
    }
}

// MARK: - Reaction pills

/// Tapback count pills under a bubble; tap one to reveal who reacted. Chips
/// pop in with a spring and counts roll with a numeric transition.
struct ChatReactionPills: View {
    let reactions: [ChatReaction]
    let myUserId: UUID?
    let isOwn: Bool
    var reactorName: (UUID) -> String = { _ in "Member" }

    @State private var expanded: String?

    var body: some View {
        Group {
            if !reactions.isEmpty {
                VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        ForEach(chatReactionCounts(reactions), id: \.emoji) { item in
                            pill(item)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    if let expanded {
                        let names = reactions.filter { $0.emoji == expanded }.map { reactorName($0.userId) }
                        if !names.isEmpty {
                            Text("\(expanded) \(names.joined(separator: ", "))")
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrTextMuted)
                                .multilineTextAlignment(isOwn ? .trailing : .leading)
                                .frame(maxWidth: 240, alignment: isOwn ? .trailing : .leading)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .transition(.scale(scale: 0.5, anchor: isOwn ? .topTrailing : .topLeading).combined(with: .opacity))
            }
        }
        .animation(MLRMotion.reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: reactions)
    }

    private func pill(_ item: (emoji: String, count: Int)) -> some View {
        let mine = reactions.contains { $0.emoji == item.emoji && $0.userId == myUserId }
        let isExpanded = expanded == item.emoji
        return Button {
            chatWithAnimation(.easeOut(duration: 0.15)) {
                expanded = isExpanded ? nil : item.emoji
            }
        } label: {
            HStack(spacing: 2) {
                Text(item.emoji).font(.mlrScaled(12))
                if item.count > 1 {
                    Text("\(item.count)")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(mine ? Color.mlrPrimary : Color.mlrTextMuted)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(mine ? Color.mlrPrimaryLight : Color.mlrCard)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isExpanded ? Color.mlrPrimary : (mine ? Color.mlrPrimary.opacity(0.4) : Color.mlrBorder), lineWidth: isExpanded ? 1.5 : 1))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("See who reacted \(item.emoji)")
    }
}

// MARK: - Pending attachments (local thumbnails with upload progress)

struct ChatPendingAttachments: View {
    let entry: ChatOutboxEntry
    let isOwn: Bool

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            ForEach(entry.payload.attachments) { att in
                thumb(att)
            }
        }
    }

    @ViewBuilder
    private func thumb(_ att: ChatAttachment) -> some View {
        Group {
            if att.kind == .image, let img = att.preview {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 240)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: att.kind == .video ? "film" : "doc.fill")
                        .foregroundStyle(Color.mlrTextMuted)
                    Text(att.filename)
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .frame(width: 220, alignment: .leading)
                .background(Color.mlrCard)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.35))
                .overlay { statusGlyph }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if entry.delivery == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white, Color.mlrDanger)
        } else if entry.progress > 0.02 {
            ZStack {
                Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: entry.progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            .animation(MLRMotion.reduceMotion ? nil : .easeOut(duration: 0.25), value: entry.progress)
        } else {
            ProgressView().tint(.white)
        }
    }
}

// MARK: - Message row chrome

/// Everything around a bubble that must feel the same in every room. The room
/// supplies the bubble (+ reactions) as `content`.
struct ChatMessageRow<Content: View>: View {
    let meta: ChatRowMeta
    let isOwn: Bool
    let authorName: String
    let avatarUrl: String?
    let createdAt: Date
    var isDeleted = false
    var delivery: ChatDelivery? = nil
    /// Swipe-to-reply. nil = not allowed (archived, can't post, unsent).
    var onReply: (() -> Void)? = nil
    /// Double-tap tapback. Returns true when it ADDED a reaction (shows the
    /// heart pop). nil = not allowed.
    var onDoubleTap: (() -> Bool)? = nil
    var onRetry: (() -> Void)? = nil
    var onDeleteUnsent: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var revealTime = false
    @State private var showFailedDialog = false

    private let avatarSize = AvatarSize.chat

    var body: some View {
        VStack(spacing: 0) {
            if let day = meta.dayLabel { ChatDaySeparator(label: day) }
            if meta.isFirstUnread { ChatNewDivider() }
            row
                .padding(.top, meta.startsGroup ? 10 : 2)
        }
        .confirmationDialog("Message not delivered", isPresented: $showFailedDialog, titleVisibility: .visible) {
            Button("Retry") { onRetry?() }
            Button("Delete", role: .destructive) { onDeleteUnsent?() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var row: some View {
        SwipeToReply(isOwn: isOwn, onReply: delivery == nil ? onReply : nil) {
            HStack(alignment: .top, spacing: 6) {
                if isOwn {
                    Spacer(minLength: 50)
                } else {
                    avatarColumn
                }
                VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                    if !isOwn && meta.startsGroup && !isDeleted {
                        Text(authorName)
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(Color.mlrTextMuted)
                            .padding(.horizontal, 4)
                    }
                    content()
                        .opacity(delivery == .sending ? 0.65 : 1)
                        .modifier(ChatTapModifier(
                            onDoubleTap: delivery == nil ? onDoubleTap : nil,
                            onTap: handleTap))
                    footer
                }
                if !isOwn { Spacer(minLength: 50) }
            }
            .padding(.horizontal, 14)
        }
        .accessibilityAction(named: "Reply") {
            if delivery == nil { onReply?() }
        }
    }

    @ViewBuilder
    private var avatarColumn: some View {
        Group {
            if meta.startsGroup && !isDeleted {
                AvatarView(url: avatarUrl, size: .chat)
            } else {
                Color.clear
            }
        }
        .frame(width: avatarSize.points, height: avatarSize.points)
    }

    private var showFooter: Bool { delivery != nil || meta.endsGroup || revealTime }

    @ViewBuilder
    private var footer: some View {
        if showFooter {
            Group {
                switch delivery {
                case .sending:
                    ChatSendingLabel()
                case .failed:
                    Button { showFailedDialog = true } label: {
                        Label("Not delivered. Tap to retry", systemImage: "exclamationmark.circle.fill")
                            .font(.mlrScaled(10, weight: .semibold))
                            .foregroundStyle(Color.mlrDanger)
                    }
                    .buttonStyle(.plain)
                case nil:
                    Text(revealTime
                         ? createdAt.formatted(date: .abbreviated, time: .shortened)
                         : createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }

    private func handleTap() {
        if delivery == .failed { showFailedDialog = true; return }
        chatWithAnimation(.snappy(duration: 0.22)) { revealTime.toggle() }
    }
}

/// "Sending…" — fades in only if the send takes noticeable time, so a fast send
/// never flickers a label.
private struct ChatSendingLabel: View {
    @State private var visible = false
    var body: some View {
        Text("Sending…")
            .font(.mlrScaled(10))
            .foregroundStyle(Color.mlrTextSubtle)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(900))
                chatWithAnimation(.easeOut(duration: 0.2)) { visible = true }
            }
    }
}

// MARK: - Tap: double-tap tapback + single tap

private struct ChatTapModifier: ViewModifier {
    let onDoubleTap: (() -> Bool)?
    let onTap: () -> Void
    @State private var burst = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if burst {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .onTapGesture(count: 2) {
                guard let onDoubleTap else { return }
                if onDoubleTap() { pop() }
            }
            .onTapGesture(count: 1) { onTap() }
    }

    private func pop() {
        chatWithAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { burst = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            chatWithAnimation(.easeOut(duration: 0.2)) { burst = false }
        }
    }
}

// MARK: - Swipe to reply

/// Drag a row toward the centre to reveal a reply arrow; past the threshold a
/// haptic fires and releasing triggers `onReply`. A high minimum distance plus a
/// horizontal-dominance check and a simultaneous gesture keep vertical
/// scrolling and the back-swipe edge untouched.
private struct SwipeToReply<Content: View>: View {
    let isOwn: Bool
    let onReply: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var dx: CGFloat = 0
    @State private var armed = false
    @State private var tracking = false
    @GestureState private var gestureActive = false

    private let threshold: CGFloat = 56

    private var progress: CGFloat { min(abs(dx) / threshold, 1) }

    var body: some View {
        if let onReply {
            ZStack(alignment: isOwn ? .trailing : .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(armed ? Color.mlrPrimary : Color.mlrTextSubtle)
                    .scaleEffect(armed ? 1.15 : 0.6 + 0.4 * progress)
                    .opacity(Double(progress))
                    .padding(.horizontal, 18)
                    .accessibilityHidden(true)
                content()
                    .offset(x: dx)
            }
            .simultaneousGesture(drag(onReply))
            .onChange(of: gestureActive) { _, active in
                // Gesture cancelled (e.g. the scroll view took over): spring back, no reply.
                if !active && tracking { reset() }
            }
        } else {
            content()
        }
    }

    private func drag(_ onReply: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($gestureActive) { _, state, _ in state = true }
            .onChanged { v in
                let w = v.translation.width, h = v.translation.height
                let toward = isOwn ? -w : w
                if !tracking {
                    // Horizontal-dominant, toward the centre, and not from the screen edge
                    // (that belongs to the back swipe).
                    guard abs(w) > abs(h) * 1.6, toward > 0,
                          isOwn || v.startLocation.x > 28 else { return }
                    tracking = true
                }
                let raw = max(0, toward)
                let eased = raw < threshold ? raw : threshold + (raw - threshold) * 0.25
                dx = (isOwn ? -1 : 1) * min(eased, 90)
                if raw >= threshold, !armed {
                    armed = true
                    Haptics.tap()
                } else if raw < threshold, armed {
                    armed = false
                }
            }
            .onEnded { _ in
                guard tracking else { return }
                let fire = armed
                reset()
                if fire { onReply() }
            }
    }

    private func reset() {
        tracking = false
        armed = false
        chatWithAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dx = 0 }
    }
}
