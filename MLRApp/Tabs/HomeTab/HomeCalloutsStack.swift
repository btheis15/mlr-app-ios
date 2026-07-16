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
    // not yet dismissed this session, and not permanently marked done (migration 0098).
    private var visibleCallouts: [HomeCallout] {
        let completed = env.festContentService.completedCalloutIds
        return env.festContentService.callouts
            .filter { $0.isLive(today: today)
                && !dismissed.contains($0.dismissId)
                && !completed.contains($0.id) }
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
        guard env.isSignedIn, let uid = await env.authService.userId else { return }
        await env.festContentService.fetchMyCalloutCompletions(userId: uid)
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

    var body: some View {
        HomeCalloutCard(callout: callout, isMarkingDone: isMarkingDone,
                        onDismiss: dismiss, onMarkDone: onMarkDone)
            .offset(x: dragX)
            .rotationEffect(.degrees(dragX / 20))
            .opacity(flying ? 0 : 1)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        dragX = v.translation.width
                    }
                    .onEnded { v in
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

    @State private var imageLoadFailed = false

    private var hasText: Bool {
        callout.title?.nilIfEmpty != nil
            || callout.body?.nilIfEmpty != nil
            || !callout.links.isEmpty
            || callout.endsOn != nil
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
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .overlay(ProgressView())
                    }
                    .onFailure { _ in imageLoadFailed = true }
                    .resizable()
                    .scaledToFit()
                    // Cap height so a tall portrait image doesn't push all content off-screen.
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipped()
                    // Dismiss X in top-right corner over the image
                    .overlay(alignment: .topTrailing) {
                        if let dismiss = onDismiss {
                            Button(action: dismiss) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 2)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
            }

            // Text block
            if hasText {
                VStack(alignment: .leading, spacing: 6) {
                    // Header row: title + dismiss X (when no image)
                    if !hasImage, let dismiss = onDismiss {
                        HStack(alignment: .top) {
                            if let title = callout.title?.nilIfEmpty {
                                Text(title)
                                    .font(.mlrScaled(14, weight: .bold))
                                    .foregroundStyle(Color.mlrText)
                            }
                            Spacer()
                            Button(action: dismiss) {
                                Image(systemName: "xmark")
                                    .font(.mlrScaled(11, weight: .semibold))
                                    .foregroundStyle(Color.mlrTextSubtle)
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if let title = callout.title?.nilIfEmpty {
                        Text(title)
                            .font(.mlrScaled(14, weight: .bold))
                            .foregroundStyle(Color.mlrText)
                    }

                    if let body = callout.body?.nilIfEmpty {
                        Text(body)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !callout.links.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(Array(callout.links.enumerated()), id: \.offset) { _, link in
                                actionButton(link: link)
                            }
                        }
                    }

                    if let ends = callout.endsOn {
                        Text("Due \(formattedDate(ends))")
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextSubtle)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(14)
            }

            // "I did this" — permanent completion button (migration 0098).
            if let markDone = onMarkDone {
                Button(action: markDone) {
                    Text(isMarkingDone ? "Marking done…" : "✓ I did this — don't show again")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.mlrSurface)
                        .overlay(
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundStyle(Color.mlrBorder),
                            alignment: .top
                        )
                }
                .buttonStyle(.plain)
                .disabled(isMarkingDone)
            }
        }
        .cardStyle()
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
        .buttonStyle(.plain)
        .padding(.top, hasAbove ? 4 : 0)
    }

    private func actionLabel(link: CalloutLink) -> some View {
        let isTel = link.href.hasPrefix("tel:")
        let isExt = link.href.hasPrefix("http://") || link.href.hasPrefix("https://")
        let digits = isTel ? String(link.href.dropFirst(4)) : nil
        return HStack {
            Text(link.label?.nilIfEmpty ?? (isTel ? "📞 Call" : isExt ? "Open link" : "✉️ Email"))
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
            Spacer()
            if let t = digits { Text(formatPhone(t)).font(.mlrScaled(13)).foregroundStyle(Color.mlrPrimary.opacity(0.7)) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.mlrPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.mlrPrimary.opacity(0.18), lineWidth: 1))
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
