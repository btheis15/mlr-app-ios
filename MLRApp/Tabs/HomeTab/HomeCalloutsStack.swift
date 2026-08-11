import SwiftUI
import Kingfisher
import TipKit

// MARK: - Callout swipe hint (TipKit)
// Mirrors the web's one-time `.callout-wiggle` nudge — teaches that a callout
// card can be swiped away. Shows once, then never again (TipKit persists this).

struct CalloutSwipeTip: Tip {
    var title: Text { Text("Swipe to dismiss") }
    var message: Text? { Text("Swipe a card away when you're done with it.") }
    var image: Image? { Image(systemName: "hand.draw") }
}

// MARK: - HomeCalloutsStack
// Swipeable admin-managed callout cards stacked above FamilyFestSpotlight on
// Home. Mirrors the web's HomeSpotlight + CalloutStack + CalloutCard pattern
// (migration 0083). FamilyFestSpotlight is the permanent non-dismissable base;
// active callout cards from `home_callouts` sit on top and can be swiped away.
//
// Dismissals are in-memory (like the web's sessionStorage): swiped cards stay
// gone while the app is open but reappear the next cold launch. Give each
// callout a versioned `dismissId` so a brand-new card resurfaces even within a
// session where an older same-purpose card was swiped.
//
// Up to 3 cards stack visually (deck-of-cards effect). Only the top card is
// interactive; the ones behind it peek out below with slight scale and offset.

private let SWIPE_THRESHOLD: CGFloat = 120
private let FLY_DISTANCE:    CGFloat = 500

struct HomeCalloutsStack: View {
    @Environment(AppEnvironment.self) private var env

    let season: FestSeason
    /// When set by the admin date-preview mode, overrides the real calendar date
    /// for callout visibility filtering. Format: `yyyy-MM-dd`.
    var previewDate: String? = nil

    // In-memory dismissals — resets on cold launch, like the web's sessionStorage.
    @State private var dismissed: Set<String> = []
    // Callout being marked done (optimistic spinner state).
    @State private var markingDoneId: String? = nil

    private var today: String {
        if let p = previewDate { return p }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        return f.string(from: Date())
    }

    // Live callouts from FestContentService, filtered to what's active today,
    // not yet dismissed this session, not permanently marked done (migration 0098),
    // and not hidden by event targeting (migration 0096 — see isHiddenForEvent).
    private var visibleCallouts: [HomeCallout] {
        let completed = env.festContentService.completedCalloutIds
        return env.festContentService.callouts
            .filter { $0.isLive(today: today)
                && !dismissed.contains($0.dismissId)
                && !completed.contains($0.id)
                && !isHiddenForEvent($0) }
    }

    /// Mirrors web's `isHiddenForEventTarget()` — deliberately narrow: hides
    /// ONLY from someone who explicitly RSVP'd "Can't make it" to the linked
    /// event. A no-response (or Going/Maybe) member still sees it.
    private func isHiddenForEvent(_ callout: HomeCallout) -> Bool {
        guard callout.excludeNotAttending, let eventId = callout.eventId else { return false }
        return env.eventsService.attendances[eventId]?.effectiveStatus() == .notGoing
    }

    var body: some View {
        let visible = visibleCallouts
        let maxDepth = min(visible.count, 3)
        // All callout cards are in one ForEach so they form a single ZStack layer
        // group, guaranteed to render in front of FestSpotlight. Cards are iterated
        // deepest-first so ZStack's back-to-front order puts card 0 on top.
        let deckCards = Array(visible.prefix(maxDepth).reversed())
        ZStack(alignment: .top) {
            // FestSpotlight is always declared first = always at the back.
            FamilyFestSpotlight(season: season)
                .offset(y: CGFloat(maxDepth) * 10)
                .scaleEffect(max(1.0 - CGFloat(maxDepth) * 0.04, 0.88), anchor: .top)

            ForEach(deckCards, id: \.id) { callout in
                if let idx = visible.firstIndex(where: { $0.id == callout.id }) {
                    if idx == 0 {
                        SwipeableCalloutCard(
                            callout: callout,
                            isMarkingDone: markingDoneId == callout.id,
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    dismissed.insert(callout.dismissId)
                                }
                            },
                            onMarkDone: { markDone(callout) }
                        )
                        .popoverTip(CalloutSwipeTip())
                    } else {
                        HomeCalloutCard(callout: callout)
                            .offset(y: CGFloat(idx) * 10)
                            .scaleEffect(1.0 - CGFloat(idx) * 0.04, anchor: .top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.bottom, CGFloat(maxDepth) * 10)
        .task { await fetchCompletions() }
        .onChange(of: env.isSignedIn) { _, nowSignedIn in
            guard nowSignedIn else { return }
            Task { await fetchCompletions() }
        }
    }

    private func fetchCompletions() async {
        // Scope to the previewed member when an admin is "seeing as" someone.
        guard env.isSignedIn, let uid = env.effectiveUserId else { return }
        await env.festContentService.fetchMyCalloutCompletions(
            userId: uid, useLocal: env.previewMember == nil)
    }

    private func markDone(_ callout: HomeCallout) {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        // Optimistic: hide immediately, write to DB in background.
        markingDoneId = callout.id
        withAnimation(.easeInOut(duration: 0.22)) {
            env.festContentService.completedCalloutIds.insert(callout.id)
        }
        Task {
            if let uid = await env.authService.userId {
                await env.festContentService.markCalloutDone(calloutId: callout.id, userId: uid)
            }
            markingDoneId = nil
        }
    }
}

// MARK: - SwipeableCalloutCard

private struct SwipeableCalloutCard: View {
    let callout: HomeCallout
    let isMarkingDone: Bool
    let onDismiss: () -> Void
    let onMarkDone: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var flying = false
    // Plays once per card so the swipe gesture reads as more discoverable than
    // the one-time-ever CalloutSwipeTip alone (which won't resurface after a
    // user has seen it a single time on any card, ever). Resets automatically
    // whenever a *new* callout becomes the front card (fresh SwiftUI identity
    // via ForEach's `id: \.id`), so each new card gets its own nudge.
    @State private var hasWiggled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HomeCalloutCard(callout: callout, isMarkingDone: isMarkingDone,
                        onDismiss: dismiss, onMarkDone: onMarkDone)
            .offset(x: dragX)
            .rotationEffect(.degrees(dragX / 20))
            .opacity(flying ? 0 : 1)
            // simultaneousGesture + a horizontal-dominance guard so vertical
            // drags stay with the page ScrollView (an exclusive, unconstrained
            // DragGesture here was swallowing Home's scroll when the finger
            // started on the callout deck).
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        dragX = v.translation.width
                    }
                    .onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragX = 0 }
                            return
                        }
                        if abs(v.translation.width) > SWIPE_THRESHOLD
                            || abs(v.predictedEndTranslation.width) > SWIPE_THRESHOLD * 1.5 {
                            fling(direction: v.translation.width > 0 ? 1 : -1)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                dragX = 0
                            }
                        }
                    }
            )
            .animation(.interactiveSpring(), value: dragX)
            .onAppear { wiggleHint() }
    }

    /// A brief, self-playing "rock left, rock right, settle" nudge — a visual
    /// hint that the card is draggable, independent of the one-time TipKit
    /// popover. Skipped when the user has Reduce Motion on.
    private func wiggleHint() {
        guard !hasWiggled, !reduceMotion else { return }
        hasWiggled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.32)) { dragX = -14 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                withAnimation(.easeInOut(duration: 0.28)) { dragX = 8 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { dragX = 0 }
                }
            }
        }
    }

    private func dismiss() {
        fling(direction: 1)
    }

    private func fling(direction: CGFloat) {
        withAnimation(.easeIn(duration: 0.22)) {
            dragX = direction * FLY_DISTANCE
            flying = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onDismiss()
            dragX = 0
            flying = false
        }
    }
}

// MARK: - HomeCalloutCard

struct HomeCalloutCard: View {
    let callout: HomeCallout
    var isMarkingDone: Bool = false
    var onDismiss: (() -> Void)? = nil
    /// When set, a "I did this — don't show again" button is shown at the bottom
    /// of the card. Tapping it permanently hides the callout for this user
    /// (migration 0098), unlike the swipe/✕ which only lasts the session.
    var onMarkDone: (() -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @State private var imageLoadFailed = false
    @State private var signupItem: ScheduleItem?
    @State private var dropBoxTarget: DropBoxTarget?

    /// The linked Fest activity (migration 0137). The Sign up button shows only
    /// when the activity actually takes sign-ups (#407).
    private var linkedActivity: ScheduleItem? {
        guard let id = callout.signupItemId else { return nil }
        return env.festContentService.schedule.first { $0.id == id }
    }

    private var hasText: Bool {
        callout.title?.nilIfEmpty != nil
            || callout.body?.nilIfEmpty != nil
            || !callout.links.isEmpty
            || callout.endsOn != nil
            || callout.dropBoxId != nil
    }

    private var hasImage: Bool {
        guard !imageLoadFailed, let url = callout.imageUrl else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image (optional flyer / artwork)
            if !imageLoadFailed, let url = callout.imageUrl?.nilIfEmpty.flatMap(URL.init) {
                KFImage(url)
                    .placeholder {
                        Color.mlrSurface
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .overlay(ProgressView())
                    }
                    .onFailure { _ in imageLoadFailed = true }
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 380)
                    .clipped()
            }

            // Text block
            if hasText {
                VStack(alignment: .leading, spacing: 0) {
                    // Eyebrow row — only text-only cards get this branded label
                    if !hasImage {
                        HStack(spacing: 5) {
                            Image(systemName: "megaphone.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("ANNOUNCEMENT")
                                .font(.system(size: 10, weight: .black))
                                .tracking(1.3)
                        }
                        .foregroundStyle(Color.mlrPrimary.opacity(0.8))
                        .padding(.bottom, 10)
                    }

                    if let title = callout.title?.nilIfEmpty {
                        Text(title)
                            .font(.mlrScaled(18, weight: .bold))
                            .foregroundStyle(Color.mlrText)
                            .padding(.trailing, onDismiss != nil ? 30 : 0)
                            .padding(.bottom, callout.body?.nilIfEmpty != nil ? 8 : 0)
                    }

                    if let body = callout.body?.nilIfEmpty {
                        Text(body)
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !callout.links.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(Array(callout.links.enumerated()), id: \.offset) { _, link in
                                actionButton(link: link)
                            }
                        }
                        .padding(.top, 12)
                    }

                    if let activity = linkedActivity, activity.signupEnabled {
                        Button { signupItem = activity } label: {
                            Text("📝 Sign up")
                                .font(.mlrScaled(14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.pressable)
                        .padding(.top, 12)
                    }

                    if let dropBoxId = callout.dropBoxId, let uuid = UUID(uuidString: dropBoxId) {
                        Button {
                            if env.isSignedIn { dropBoxTarget = DropBoxTarget(id: uuid) }
                            else { env.authService.promptSignIn() }
                        } label: {
                            Text("📸 Add & see photos")
                                .font(.mlrScaled(14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.pressable)
                        .padding(.top, 12)
                    }

                    if let ends = callout.endsOn {
                        Text("Due \(formattedDate(ends))")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 10)
                    }
                }
                .padding(hasImage ? 16 : 20)
            }

            // "I did this" — permanent completion button (migration 0098).
            if let markDone = onMarkDone {
                Button(action: markDone) {
                    Text(isMarkingDone ? "Marking done…" : "✓ I did this — don't show again")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.mlrSurface)
                        .overlay(
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Color.mlrBorder),
                            alignment: .top
                        )
                }
                .buttonStyle(.pressable)
                .disabled(isMarkingDone)
            }
        }
        // Rich gradient background for text-only cards; plain for image cards.
        .background {
            ZStack {
                Color.mlrCard
                if !hasImage {
                    LinearGradient(
                        colors: [Color.mlrPrimary.opacity(0.11), Color.mlrPrimary.opacity(0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    LinearGradient(
                        colors: hasImage
                            ? [Color.mlrBorder, Color.mlrBorder]
                            : [Color.mlrPrimary.opacity(0.5), Color.mlrPrimary.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        }
        .shadow(color: hasImage ? .black.opacity(0.09) : Color.mlrPrimary.opacity(0.15),
                radius: 18, x: 0, y: 7)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        // Floating dismiss — pill button in the top-right corner
        .overlay(alignment: .topTrailing) {
            if let dismiss = onDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hasImage ? Color.white : Color.mlrTextSubtle)
                        .frame(width: 26, height: 26)
                        .background(hasImage
                            ? AnyShapeStyle(.black.opacity(0.35))
                            : AnyShapeStyle(.ultraThinMaterial))
                        .clipShape(Circle())
                }
                .buttonStyle(.pressable)
                .padding(12)
            }
        }
        .sheet(item: $signupItem) { item in
            NavigationStack { FestScheduleDetailView(item: item) }
        }
        .sheet(item: $dropBoxTarget) { target in
            NavigationStack { DropBoxDetailView(boxId: target.id) }
        }
    }

    @ViewBuilder
    private func actionButton(link: CalloutLink) -> some View {
        let hasAbove = callout.title?.nilIfEmpty != nil || callout.body?.nilIfEmpty != nil
        Group {
            if let url = URL(string: link.href) {
                Link(destination: url) { actionLabel(link: link) }
            } else {
                actionLabel(link: link)
            }
        }
        .buttonStyle(.pressable)
        .padding(.top, hasAbove ? 4 : 0)
    }

    private func actionLabel(link: CalloutLink) -> some View {
        let isTel = link.href.hasPrefix("tel:")
        let isExt = link.href.hasPrefix("http://") || link.href.hasPrefix("https://")
        let digits = isTel ? String(link.href.dropFirst(4)) : nil
        return HStack {
            Text(link.label?.nilIfEmpty ?? (isTel ? "📞 Call" : isExt ? "Open link" : "✉️ Email"))
                .font(.mlrScaled(14, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
            Spacer()
            if let t = digits { Text(formatPhone(t)).font(.mlrScaled(13)).foregroundStyle(Color.mlrPrimary.opacity(0.7)) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.mlrPrimary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mlrPrimary.opacity(0.22), lineWidth: 1))
    }

    private func formattedDate(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: d)
    }

    private func formatPhone(_ digits: String) -> String {
        let d = digits.filter(\.isNumber)
        guard d.count == 10 else { return digits }
        let area  = d.prefix(3)
        let mid   = d.dropFirst(3).prefix(3)
        let last  = d.dropFirst(6)
        return "(\(area)) \(mid)-\(last)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// UUID isn't Identifiable on its own — this wraps a Drop Box id for `.sheet(item:)`.
private struct DropBoxTarget: Identifiable {
    let id: UUID
}
