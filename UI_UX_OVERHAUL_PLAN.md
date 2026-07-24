# MLR App — Bold UI/UX Overhaul (Implementation Plan)

> **For Claude in Xcode:** This is an implementation spec, not finished code.
> Implement against the **latest `main`**. Work top-to-bottom by phase; each phase
> is independently buildable and shippable. iOS 18 target, Swift 5. After every
> phase, compile clean and visually verify in the simulator (light + dark +
> Reduce Motion + large Dynamic Type). **All new motion MUST have a Reduce-Motion
> fallback** (match the existing `SkeletonPulseModifier` / `ExpandableScheduleRow`
> convention). Reuse the named existing helpers — do not reinvent them. Line
> numbers are approximate hints; anchor on the named symbols.

## Context & goal

The app is feature-complete but feels flat and static outside the Family Fest
tab. It already owns a strong toolkit — glass button styles with spring
press-scale, brand gradients, `ConfettiView`, symbol effects, `Haptics`,
numeric-roll counters, `PulsingLiveDot`, skeletons, a full adaptive light/dark
color system — but almost all of it is used **only in Family Fest**. Elsewhere:
hairline borders instead of elevation (`cardStyle(elevated:true)` is used **0
times** in real call sites), flat fills instead of gradients, `.buttonStyle(.plain)`
on ~150 tappable cards (no press feedback), and almost no entrance motion
(`matchedGeometryEffect`, `.navigationTransition(.zoom)`, `MeshGradient` = **0
uses**; `.scrollTransition` = 1; `.symbolEffect` = 1). There is no
spacing/radius/elevation token file — values are inline everywhere.

**Direction:** bolder — dramatic mesh-gradient heroes, more color per feature
area, bigger typographic moments, celebratory moments, premium feel — while
keeping the Northwoods brand (forest green / campfire orange) and the Fest
heraldic sub-world intact.

**Rollout:** flagship-first. Build a shared foundation, then deeply transform the
priority surfaces (Private Activities + Tournaments/Brackets, and Family Fest),
then Home/Events, then a lighter Feed pass and a mechanical broad sweep.

### iOS compatibility guardrail (REQUIRED)
The deployment target is **iOS 18.0** and the app must run on iOS 18 and above.
Every API in this plan is iOS 18-safe:
- **iOS 18.0:** `MeshGradient`, `.navigationTransition(.zoom)` / `matchedTransitionSource`, `onScrollGeometryChange`.
- **iOS 17:** `.sensoryFeedback`, `.symbolEffect(.bounce/.pulse/.replace)`, `.scrollTransition`, Charts `SectorMark`.
- **iOS 16/earlier:** `.contentTransition(.numericText())`, `matchedGeometryEffect`, `Canvas`/`Path`, `.anchorPreference`.

Rules: **Do NOT introduce any API that requires iOS 19+ / iOS 26 without an
`#available` guard and an iOS 18 fallback.** The only iOS 26 feature in the app is
Liquid Glass, which is already `#available(iOS 26.0, *)`-gated in
`LiquidGlass.swift` with solid-fill fallbacks — keep routing all "glass" through
those existing helpers; never call `.glassEffect`/`.buttonStyle(.glass)` or other
26-only symbols directly. New foundation styles (`.pressable`, mesh hero, entrance
motion) are non-glass and iOS 18-native, so they never touch the 26 path. If any
future refinement wants a newer API, gate it and provide the iOS 18 path.

**Priority surfaces (user-called-out):**
1. **Private activities + tournament brackets** — real and functional today, but
   visually plain. This is the marquee "wow" surface (the user specifically wants
   a *big bracket view* and life/visuals in the create-a-game flow).
2. **Family Fest** — richer/dramatic colors, larger fonts, and collapsible
   "anytime" cards to match the weekday cards.

---

## Phase 1 — Foundation layer (do first; highest leverage)

Concentrate change in `MLRApp/Shared/Design/` so ~150 flat views lift with minimal churn.

### 1.1 New — `MLRApp/Shared/Design/Metrics.swift`
- `enum MLRSpacing`: `xs=4, sm=8, md=12, lg=16, xl=24, xxl=32`; aliases `page=16`, `cardInset=16`, `stack=12`.
- `enum MLRRadius`: `sm=8, button=14, card=16, lg=18, xl=24, pill=999`.
- `enum MLRElevation { none, low, medium, high, hero }` with `color/opacity/radius/y`:
  `none`=0; `low`=0.06/r10/y4 (== today's `elevated:true`); `medium`=0.10/r16/y8; `high`=0.14/r22/y12; `hero`=0.20/r30/y18.
- `extension View { func shadow(_ level: MLRElevation) -> some View }`.
- Dark mode: shadows are near-invisible on OLED (intended); lift there comes from tint/gradient variants + press-scale, not shadow opacity.

### 1.2 New — `MLRApp/Shared/Design/Motion.swift`
- `enum MLRMotion`: `spring = .spring(response:0.34, damping:0.72)`, `entrance = .spring(response:0.45, damping:0.8)`, `staggerStep=0.05`, `maxStaggerIndex=8`, `reduceMotion` bridge.
- `.scrollEntrance(scale:0.96, rise:14)` — generalizes the existing `.scrollTransition` in `FestOverviewView`. No-op under Reduce Motion.
- `.cardEntrance(index:)` — one-shot staggered fade+rise for non-lazy content; caps delay at `maxStaggerIndex`; no-op under Reduce Motion.
- `struct MLRPressableButtonStyle` as `.buttonStyle(.pressable)` — spring scale 0.97 + opacity 0.92 + light `.sensoryFeedback(.impact(weight:.light))`; scale suppressed under Reduce Motion. Drop-in for `.buttonStyle(.plain)`.

### 1.3 New — `MLRApp/Shared/Design/Feedback.swift`
- `.mlrFeedback(_:trigger:)` wrapping iOS 17 `.sensoryFeedback` (default for new code; leave the 32 imperative `Haptics.*` sites).
- `struct FeedbackSymbol` — tappable SF Symbol that bounces/pulses/replaces + fires a haptic; gate `.bounce` behind `!reduceMotion`.
- `.numericTransition()` wrapping `.contentTransition(.numericText())`.

### 1.4 New — `MLRApp/Shared/Components/MeshHeroBackground.swift`
- `enum HeroTheme { case northwoods, fest, accent(Color) }` with `points`, adaptive `colors`, and a `LinearGradient fallback` (maps to existing `.northwoodsSunset` / `.festHeraldic`).
- `struct MeshHeroBackground: View` — iOS 18 `MeshGradient` (3×3) with slow point-drift frozen under Reduce Motion.
- `.heroOverlayScrim()` — bottom-to-top `black.opacity(0→0.25)` for legibility (honors the "black scrim only" rule in `Colors.swift`). One mesh per visible hero; never behind a scrolling `LazyVStack`.

### 1.5 Changed — `MLRApp/Shared/Design/Typography.swift` (back-compatible signatures)
- **Bump `cardStyle` default elevation:** `elevated:false` → `.low`; `elevated:true` → `.medium`. Removes most of the "flat" feel with zero call-site edits. Add `elevation:.none` opt-out for grouped-list rows.
- Add `cardStyle(tint:elevation:)` (accent-washed border + faint top-edge gradient) and `gradientCard(_:elevation:)` (full gradient fill) reusing the brand gradients.
- Add `.interactiveCard(elevation:index:haptic:action:)` + `interactiveFestCard(...)` — composes `Button` + `.pressable` + `cardStyle` + optional `.cardEntrance`. Drop-in for `Button{…}.buttonStyle(.plain).cardStyle()`.

---

## Phase 2 — Private Activities + Tournaments / Brackets (marquee flagship)

Files (all exist on main): `MLRApp/Events/PrivateActivityViews.swift`,
`TournamentContainerView.swift`, `TournamentManageViews.swift`; models
`MLRApp/Models/{PrivateActivity,Tournament}.swift`; entry in `EventsView.swift`
(`activitiesSection`, the `+` → "Create an activity or game" menu). **Services and
models are complete — this phase is UI/UX only; do not change backend calls or
bracket math** (`BracketMath`, `Tournament.standings()`, `bracketMatches`, `maxRound`).

### 2.1 "Create an activity or game" composer — `PrivateActivityComposer`
Today a plain `Form`. Make creating a game feel fun:
- **Live preview card** pinned at top that updates as you type — the activity as it
  will appear (big emoji medallion + title + a gold `trophy.fill` badge when
  "Run a tournament" is on). Reuse the enhanced `PrivateActivityRow` look (2.2).
- **Emoji quick-pick:** a horizontal row of common game emojis (🎲 🏆 🎯 🃏 🏐 ⛳️ 🏓 🎱 🥏 🪃) + the free-text field; tap to fill `emoji`. `.pressable` + `.mlrFeedback(.selection)`.
- **Animated reveal** of the tournament explanation when `tournamentEnabled` toggles (`.transition(.move+.opacity)` gated on Reduce Motion).
- **Invited people as avatar chips** using `AvatarView(size:.small)` + name, removable; keep the typed-name (off-app) path.
- Keep all create logic (`privateActivitiesService.create`) and the `MemberMultiPicker`.

### 2.2 Activity row — `PrivateActivityRow`
- `.interactiveCard(elevation:.medium)` + `.pressable`; emoji medallion gets a tinted gradient chip; tournament badge becomes a small gold gradient pill; add a going-count `.numericTransition()` and a small overlapping `AvatarView` host stack. Wire `.scrollEntrance()` where listed in `EventsView.activitiesSection`.

### 2.3 Activity detail — `PrivateActivitySheet`
Today a plain `List`. Give it a hero + celebration:
- **Hero header:** `MeshHeroBackground(theme:.accent(.mlrPrimary))` band with a large emoji medallion, title, host names, and a going-count `.numericTransition()`.
- **RSVP:** keep the `ActivityRsvp` segmented control, but fire a **`ConfettiView` burst + `Haptics.success()`** when the viewer picks `.going` (track via `onChange`). Each option shows its emoji (already in the model).
- **Members:** rows with `AvatarView`, host pill, and the RSVP emoji; `.scrollEntrance()`.
- **Tournament CTA:** replace the plain `NavigationLink` "Open tournament" row with a prominent **gradient CTA card** (`gradientCard(.festHeraldic-like gold)`, `trophy.fill` with `.symbolEffect`, a one-line status like "Bracket · live" from `Tournament.status`). Navigates to `TournamentContainerView`.

### 2.4 THE BIG BRACKET VIEW — `TournamentContainerView` + new `BracketDiagram`
Today `TournamentBracketView` is a **round-pager** (segmented Picker, one round of
flat `MatchCard`s at a time) — functional but not the "big bracket" the user wants.
Build a real connected bracket as the default for `single_elim` and the knockout
stage of `pools_bracket`:
- **New `MLRApp/Events/BracketDiagram.swift`:** a `ScrollView([.horizontal, .vertical])`
  containing an `HStack(alignment:.center)` of **round columns**. Each column is a
  `VStack` of match cells, vertically spaced so each match sits at the midpoint of
  its two feeder matches (compute positions from `round`/`position`; the tree shape
  is regular since `bracketSize` is a power of two). Drive it from
  `Tournament.bracketMatches` grouped by `round` (use `maxRound`).
- **Connectors:** draw elbow lines from each match to its parent using `nextMatchId`
  / `nextSlot`. Capture per-cell frames with `.anchorPreference(key:value:)` +
  `.overlayPreferenceValue { anchors in Canvas/Path … }` (or a `coordinateSpace` +
  `GeometryReader`), then stroke connectors in a `Canvas`/`Path` overlay in `Color.mlrBorder`
  (winner-path segments in `Color.mlrPrimary`). Champion node at the far right:
  a gold `gradientCard` with `trophy.fill`.
- **Fallback:** keep the existing round-pager as a compact mode — use it under
  Reduce Motion, for very large draws (e.g. `maxRound` beyond a threshold), or via a
  segmented "Diagram / By round" toggle. Round-robin/pools keep the existing
  standings/games/pool tabs.
- **Champion reveal (replace the plain `Label`):** a `ChampionBanner` — gold
  gradient card, `trophy.fill` + `.symbolEffect(.bounce)`, big winner name — and fire
  **`ConfettiView` + `Haptics.success()` once** when `winnerEntrantId` transitions to
  non-nil (`onChange`). This is the marketing centerpiece.

### 2.5 Match cell / card — `MatchCard` (and the diagram cell)
- `.cardStyle(elevation:.medium)` + `.pressable`; seed badges from `entrant.seed`;
  winner row gets a gold accent bar + bold + a small `crown.fill`; scores use
  `.numericTransition()`; `.ready`/`.in_progress` shows a `PulsingLiveDot`; scheduled
  time chip stays. `Haptics.tap()` on tap-to-score; keep the rearrange tap-to-swap
  (highlight the picked-up slot more boldly with `Color.mlrPrimary` fill + scale).

### 2.6 Standings — `StandingsTable`
- Medal treatment for ranks 1–3 (gold/silver/bronze row tint + medal SF Symbol),
  keep the leader `crown.fill`, add a subtle win% mini-bar per row, `.cardStyle(elevation:.low)`,
  and animate rank/record changes with `.numericTransition()`.

### 2.7 Setup & scoring sheets — `TournamentSetupSheet`, `MatchResultSheet`
- **Setup:** format selection as tappable **cards with icons** (bracket / round-robin /
  pools) instead of a bare segmented picker; a **live mini connected-bracket preview**
  that redraws as seeds reorder (reuse `BracketMath.firstRoundPreview` / `seedOrder`,
  render with a small `BracketDiagram`); `.mlrFeedback(.selection)` on drag-reorder.
  Keep all `tournamentsService` calls and the drag-to-reorder/`onMove`/`onDelete` logic.
- **MatchResultSheet:** make the two winner options big tappable **cards with
  `AvatarView`** and a central "VS"; animated `checkmark` (`.symbolEffect(.bounce)`) on
  pick; **`ConfettiView` + `Haptics.success()`** on "Save & advance." Keep the optional
  scores, notify, schedule, and downstream-reset warning exactly.

---

## Phase 3 — Family Fest refresh (priority)

Tokens in `MLRApp/Shared/Design/Colors.swift` (unchanged on main), fonts in
`Typography.swift`, views in `MLRApp/Tabs/FamilyFestTab/*`.

### 3.1 Richer, dramatic palette — `Colors.swift` lines 43–58
Reads bland because it's applied at low opacity over a near-white parchment with a
pure-white card and a muted ochre gold. Deepen/warm (starting values; tune in-sim):

| Token | Current light | Current dark | Proposed light | Proposed dark |
|---|---|---|---|---|
| `mlrFest` (wine) | `#801c32` | `#D85A77` | `#6B0F24` | `#E0708A` |
| `mlrFestLight` | `#fdf6f0` | `#302820` | `#F6E4CF` | `#3A2A22` |
| `mlrFestParchment` (bg) | `#f5ede0` | `#221B15` | `#ECDCBE` | `#1E1712` |
| `mlrFestCard` | `#ffffff` | `#3A2E22` | `#FBF3E1` | `#40332A` |
| `mlrFestInk` (text) | `#3a2a18` | `#EDE3D3` | `#33240F` | `#F1E7D6` |
| `mlrFestGold` | `#a67c1a` | `#D9B24C` | `#C29A2E` | `#E7C05A` |

Then raise the *application* (the real fix): in `festCardStyle` (`Typography.swift`),
raise the gold hairline from `mlrFestGold.opacity(0.35)` toward `0.6`, bump shadow to
`.medium`, add a low-opacity `festHeraldic` top-edge wash; raise pervasive
`mlrFest.opacity(0.1–0.15)` dividers toward `0.25–0.35`; use `festHeraldic` +
`FestHeroGlow` behind the Fest cover instead of flat fills.

### 3.2 Larger Fest fonts (the "too small" fix)
Card titles are Cinzel bold at only **14pt**, descriptions **12pt**. Bump the
theme-relevant sizes (anchor on symbols; approximate lines on latest main):
- `FestAnytimeCard` item title `festSerif(14,bold)` (~`FestOverviewView.swift:412`) → `festSerif(18,bold)`; its description `mlrScaled(12)` → `mlrScaled(15)`.
- Day name header `mlrScaled(11,semibold)` → `mlrScaled(14)`.
- `FestInfoCard` title `festSerif(15,bold)` → `festSerif(19,bold)`.
- Cover theme/date lines `festSerif(14/15)` → `festSerif(17/19)`.
- `ExpandableScheduleRow` title `festSerif(14,bold)` (`FestScheduleDetailView.swift`) → `festSerif(18,bold)`; time/hint `mlrScaled(12)` → `mlrScaled(14)`.
- `FestStatus` serif titles `festSerif(16)` → `festSerif(19)`.
All are Dynamic-Type-aware — re-check the largest accessibility size doesn't clip.

### 3.3 Collapsible "anytime all week" cards (key ask)
The reusable collapsible component **already exists** — reuse it, don't build new.
- Component: **`ExpandableScheduleRow`** (`FestScheduleDetailView.swift`) — `@State isExpanded`,
  `withAnimation(.easeInOut(0.22))` gated on Reduce Motion, `.sensoryFeedback(.selection)`,
  rotating chevron, full a11y, `expanded` body reusing `DetailSection`/`LeadRow`/`ProtectedField`.
- Weekdays use it via **`FestDaySection`** (`FestOverviewView.swift:~242`): a `VStack(spacing:0)`
  of `ExpandableScheduleRow` separated by `Divider()`, wrapped in `.festCardStyle(cornerRadius:12)`.
- **Fix:** in **`FestAnytimeCard`** (`FestOverviewView.swift:~382`), replace the flat
  `FestInfoCard { ForEach … }` body with the same structure as `FestDaySection` —
  a `VStack(spacing:0)` of `ExpandableScheduleRow(item:)` separated by
  `Divider().background(Color.mlrFest.opacity(0.15))`, wrapped in `.festCardStyle(cornerRadius:12)`,
  keeping the "All week — anytime" heading above.
- **Watch-out (edit routing):** `ExpandableScheduleRow`'s edit button opens
  `FestScheduleEditSheet`, whereas the anytime card currently opens `FestActivityEditSheet`.
  Prefer adding an optional `editSheet` closure parameter to `ExpandableScheduleRow` so
  anytime items keep `FestActivityEditSheet`; confirm the admin edit flow still works.
- `ScheduleItem` model: `MLRApp/Models/SeedData.swift` (`day, isoDate?, time, title, location?, description?, isPrivate, leads, …`). The anytime seed item has both location + description, so `hasDetail` is true and it expands correctly.

---

## Phase 4 — Home dashboard flagship
Files: `MLRApp/Tabs/HomeTab/HomeView.swift` + `Tabs/HomeTab/*`.
- New `Tabs/HomeTab/HomeHero.swift`: full-bleed `MeshHeroBackground(theme:.northwoods)`
  (~260–300pt, `.ignoresSafeArea(edges:.top)`), content floating over it; centered logo +
  the **Yellowtail script wordmark** (`Font.script`, unused on Home) + a time-of-day
  greeting; search/date buttons become translucent glass circles with `FeedbackSymbol`
  + `Haptics.tap`; subtle scroll parallax via `onScrollGeometryChange`, frozen under Reduce Motion.
- Per-section accent identity (weather→`mlrLake`, birthdays→`mlrSun`, who's-up-north→`mlrCampfire`)
  as a leading edge-bar / icon-chip tint, not full fills.
- `HomeTile`: `.interactiveCard` press-scale, gradient icon chips, `.symbolEffect(.bounce)`;
  promote the Events tile to a full-width "hero tile" with a mini mesh wash. Keep all six `NavigationLink` destinations.
- `.scrollEntrance()` on the section stack, first-appearance only (guard vs `.refreshable`).

---

## Phase 5 — Events list flagship
Files: `MLRApp/Events/EventsView.swift`, `EventCard.swift`, `EventSheet.swift`.
- `EventsView`: slim `MeshHeroBackground` masthead; bold month headers (`mlrScaled(20,bold,rounded)`
  + `mlrCampfire` rule + `.numericText()` count); `.scrollEntrance()` on cards; bg → `mlrSurface`.
  Keep the Upcoming/Past picker, the `+` menu, and the "Games & activities" `activitiesSection`.
- `EventCard`: new shared `Events/DateMedallion.swift` (bold day/month in a kind-tinted gradient
  square), kind color band, `.cardStyle(elevation:.medium)` + `.pressable`, `.numericText()` going
  count + mini `AvatarView` stack, `.matchedTransitionSource(id:event.id, in:)`. Fest events keep identity.
- **Card→detail zoom morph:** convert `selectedEvent` from `.sheet(item:)` to
  `.navigationDestination(item:)` and present with `.navigationTransition(.zoom(sourceID:in:))`
  (fall back to `matchedGeometryEffect` on the medallion where a sheet must stay).
- `EventSheet`: new `Events/EventHero.swift` — cinematic `MeshHeroBackground(theme:.event(kind))`
  header with glass `KindBadge`, big title, the morphed `DateMedallion`, what/when/where on the
  mesh; `GoldOrnamentDivider` for Fest. Detail rows → tinted chips. Native actions get `.pressable`
  + `.symbolEffect(.bounce)`. RSVP: keep `AttendanceControl`, add a hero-wide `ConfettiView` on a fresh
  "Going." The existing `Charts SectorMark` donut gets spring sector growth + a bold `.numericText()`
  center total. Extend `EventKindStyle` with `meshTheme(for:)`/`gradient(for:)`.

---

## Phase 6 — Feed (lighter) + broad sweep
- **Feed** (`Tabs/FeedTab/PostsView.swift`, `PostCard.swift`, `PostComposer.swift`, `LightboxView.swift`):
  elevated `.interactiveCard` posts, `.numericText()` reaction counts, `.symbolEffect(.bounce)` + haptic on
  reaction, photo→`LightboxView` zoom morph, staggered entrance, slim `MeshHeroBackground` masthead.
  Note recent additions to respect/polish: post editing now **adds/removes media** and posts can show
  **moderation banners** — style the moderation banner consistently with `AnnouncementBanner`'s
  `.warning` variant, and give the media add/remove controls `.pressable` + a small `.symbolEffect` on add/remove.
- **`TeeTimesView`** (`Tabs/HomeTab/TeeTimesView.swift`, new): quick polish win — make the day-pick
  chips `.pressable` capsule buttons with a golf-tinted accent, elevate the "call" and "Daily Deals"
  `Link` blocks to `.cardStyle(elevation:.medium)`, add `.scrollEntrance()`, and consider a slim
  `MeshHeroBackground(theme:.accent(.mlrLake))` header. Keep the existing `SectionLabel` + foreUP/Daily Deals links.
- **Chat reply-to** (`Committees/CommitteeChatView.swift`, `Houses/HouseChatView.swift`, new): style the
  reply-to quoted-message preview as a tinted, rounded quote strip (leading accent bar + `mlrTextMuted`),
  with `.pressable` on the reply affordance — part of the sweep, not a deep redesign.
- **Broad sweep** (mechanical, tab-by-tab): `.buttonStyle(.plain)` → `.buttonStyle(.pressable)`
  (~150 sites / 65 files); `Button{…}.plain.cardStyle()` → `.interactiveCard`; inline literals → tokens;
  `.scrollEntrance()` on list `ForEach`s (People, Committees, Cabins, Notifications, Polls…);
  `FeedbackSymbol`/`.mlrFeedback`/`.numericTransition()` on delight moments (poll votes, pay taps,
  callout swipes, live dots); token cleanup of ~28 raw `Color.blue/.red/.gray` and the inlined
  Tailwind hexes in `AnnouncementBanner.swift`; unify auth/onboarding `Color(.systemGray6)` inputs onto `.fieldStyle()`.

---

## Phase 7 — Notification sender avatars

Two layers. Part A is pure Swift and fully in scope; Part B adds a new Xcode
target + entitlement and depends on a backend payload change.

### 7.A In-app notification list (in scope, Swift only)
`MLRApp/Tabs/ActivityTab/NotificationRow.swift` already renders an actor avatar
from `AppNotification.actorAvatarUrl` / `actorName` (model:
`MLRApp/Models/Notification.swift`) — but via raw `AsyncImage` with a
letter/kind-icon fallback (`actorAvatar` / `placeholderAvatar` / `kindIconAvatar`,
~lines 44–137). Upgrade it:
- Replace the `AsyncImage` block with the app's **`AvatarView`** (`Shared/Components/AvatarView.swift`)
  for Kingfisher caching, the admin ring, and consistent `AvatarSize`; keep the
  `kindIconAvatar` as the fallback when `actorAvatarUrl`/`actorName` are nil (system events).
- Add `.pressable`, `.scrollEntrance()`, and unread-state polish (the row already tints unread).
- No model/service/backend change — the data is already present.

### 7.B Push-banner sender avatar — communication-style (new target + entitlement + backend)
Goal: the iMessage-style **circular sender avatar** on the lock-screen/banner, with the
notification attributed to the person. Available since iOS 15 — **iOS 18-safe**. Today
there is **no Notification Service Extension** and the payload attaches no image, so
banners show only the app icon.

iOS-side work (Claude in Xcode can author this):
1. **New target:** a `UNNotificationServiceExtension` (e.g. `MLRNotificationService/`).
   In `didReceive(_:withContentHandler:)`: read the actor avatar URL + sender name from the
   payload's custom data, download the image, build an `INImage` from it, construct an
   `INSendMessageIntent` with an `INPerson` sender carrying that image, `donate()` the
   `INInteraction`, then return `try request.content.updating(from: intent)`. Handle the
   `serviceExtensionTimeWillExpire` fallback (deliver original content).
2. **Entitlement/capability:** add **Communication Notifications**
   (`com.apple.developer.usernotifications.communication`) to the app target (and the
   extension as needed); enable the Siri/Intents capability the intent donation requires.
   These are Xcode/entitlement config the user owns.
3. Keep the existing `UNNotificationCategory` actions in `MLRApp/Native/NotificationActions.swift`.

Backend dependency (NOT in this iOS repo — document, do not fake it):
- The push sender (a **Supabase edge function** in the backend/web repo) must set
  **`mutable-content: 1`** in the `aps` payload and include the actor's **avatar URL** and
  **display name** in the notification's custom data. The extension only enriches banners
  whose payload carries these; without the backend change the app degrades gracefully to the
  current icon-only banner. Note this dependency clearly in the PR/description.

Compatibility: `UNNotificationServiceExtension`, `INSendMessageIntent`, `INImage`,
`content.updating(from:)`, and Communication Notifications are all iOS 15+ — no iOS 26
dependency; no `#available` gate needed for the iOS 18 floor.

## Phase 8 — Composer "clean slate" reset (behavior fix)

Problem: attaching/reminding-about an activity **autofills** the composer, but
there's no way to switch back to a fresh, blank notification — the autofilled
title/body/link/targeting stay put, forcing manual deletion of each field.

Primary file: `MLRApp/Tabs/ProfileTab/Admin/AdminBroadcastComposer.swift`. The
"Remind about an activity (autofills)" `Menu` (~lines 52–66) calls
`autofill(from:)` (~lines 183–192), which sets `title`, `messageBody`,
`selectedEventId`, `excludeNotAttending`, and `linkUrl`.

Fix:
- Add a **`resetToBlank()`** that returns ALL composer state to its initial
  defaults: `title=""`, `messageBody=""`, `kind = .info`, `expiry = .sixHours`,
  `audience = .everyone`, `toBanner = true`, `toActivity = false`, `toEmail = false`,
  `selectedEventId = nil`, `excludeNotAttending = true`, `linkUrl = nil`,
  `scheduleAt = nil`, `error = nil` (do not touch `isPosting`/`posted`).
- Surface it inside the existing `Menu`: keep the activity list, then a `Divider()`,
  then a destructive **"Start fresh (clear all)"** `Button(role: .destructive)` that
  calls `resetToBlank()`. Rename the menu label to reflect both actions (e.g.
  "Attach an activity / start fresh"). Add `Haptics.tap()` on selection.
- **Guard against accidental wipes:** if any content field is non-empty, route the
  "Start fresh" tap through a `.confirmationDialog` ("Clear this notification?") before
  resetting; if everything is already blank, reset silently. This satisfies "I don't
  have to delete everything" without nuking real work on a mis-tap.

Mirror the same `resetToBlank()` + "Start fresh" affordance in the sibling composers
that autofill/attach or target an event —
`MLRApp/Tabs/ProfileTab/Admin/AdminNotificationComposer.swift` and
`AdminAlertComposer.swift` (each has `title`/`messageBody`/`selectedEventId`/link
state and an `EventTargetPicker`) — so "callout or notification" both get the clean
slate. Pure Swift state reset; no backend change; iOS 18-safe.

**Callouts (updated on main):** the callout composer in
`MLRApp/Tabs/ProfileTab/Admin/AdminCalloutsView.swift` now links a Fest activity via
a "Link a Fest activity" `Picker` bound to `signupItemId` (which drives the auto "📝
Sign up" button). Its `resetToBlank()` must ALSO clear `signupItemId = nil` alongside
`title`/`body_`/`links`/`imageUrl`/`startsOn`/`endsOn`/dates, and the picker must keep
a "None" option so an admin can unlink the activity without discarding the whole
callout. (The composer already resets on open for new callouts; this makes
attach→change-your-mind reversible in-session too.)

## Reused existing helpers (do not reinvent)
- Colors: `Color.mlr*`, `Color(hex:)`, `Color(light:dark:)` (`Colors.swift`).
- Type/recipes: `.mlrScaled()`, `Font.script`, `Font.festSerif`, `LinearGradient.northwoodsSunset`/`.festHeraldic`, `SectionLabel`, `festCardStyle`.
- Glass: `GlassPrimary/Secondary/Fest/CircleButtonStyle`, `.glassCard()` (`LiquidGlass.swift`).
- Haptics: `Haptics` enum (`Native/HapticsAndShare.swift`).
- Components: `AvatarView`, `AttendanceControl`, `ConfettiView` (trigger:Int), `SkeletonView`, `KindBadge`, `ExpandableScheduleRow`, `FestDaySection`, `FestHeroGlow`, `GoldOrnamentDivider`, `PulsingLiveDot`.
- Tournament domain (keep as-is): `BracketMath`, `Tournament.standings()`, `bracketMatches`, `maxRound`, `TournamentsService`, `PrivateActivitiesService`.

## Accessibility (required every phase)
- Every motion path (`scrollEntrance`, `cardEntrance`, `.pressable` scale, mesh drift, symbol bounce,
  disclosure animation, bracket connectors) checks Reduce Motion and degrades to static/opacity-only.
- Test large Dynamic Type after Fest font bumps — no clipping.
- Bracket diagram: provide the round-pager fallback for Reduce Motion / very large draws; keep VoiceOver labels on match cells.
- Keep haptics at light/selection tier.

## Verification (no UI test suite; verify by build + run)
1. Build clean: `xcodebuild -project "MLR App.xcodeproj" -scheme "MLR App" -destination 'generic/platform=iOS Simulator' build`.
2. Phase 1: every card app-wide gains subtle elevation (light + dark); tapping any card gives spring press feedback; no layout regressions on grouped-list rows.
3. Phase 2: create an activity/game (live preview updates, emoji pick, confetti on RSVP "Going"); open a tournament and see the **connected bracket with connector lines**, animated scores, a `PulsingLiveDot` on live matches, medal-styled standings, and a **confetti champion reveal**; setup shows a live bracket preview as seeds reorder; scoring shows VS cards + confetti on advance.
4. Phase 3: Fest palette reads rich/gilded (not beige-on-white); fonts visibly larger; the "All week — anytime" items expand/collapse exactly like weekday items; admin edit still works.
5. Phases 4–5: mesh heroes, parallax, script wordmark, card→sheet zoom morph, hero-wide confetti on RSVP, animated counters.
6. Reduce Motion ON: all movement suppressed to static/opacity-only; bracket falls back to the round-pager.
7. Phase 7A: the Activity-tab notification list shows cached `AvatarView` sender photos (admin ring where applicable), with the kind-icon fallback for system events. Phase 7B: with a test push carrying `mutable-content:1` + an avatar URL, the banner shows the circular sender avatar; without those fields it degrades to the icon-only banner (no crash). Confirm the Communication Notifications entitlement is present on the app + extension targets.
8. Phase 8: in the broadcast composer, attach an activity (fields autofill), then pick "Start fresh (clear all)" → every field returns to blank/defaults; the confirmation appears only when there was content. Same in the notification + alert composers. In the callout composer, link a Fest activity then reset → `signupItemId` clears and the "📝 Sign up" button disappears; the picker's "None" unlinks without clearing the rest.
8b. New screens polished: `TeeTimesView` chips are pressable and the Daily Deals/call blocks are elevated; Feed post moderation banners match the `AnnouncementBanner` warning style; chat reply-to quotes render as a tinted quote strip.
9. Performance: long lists scroll smoothly (stagger capped at index 8); the bracket diagram scrolls smoothly for a 16+ entrant draw; no mesh behind scrolling content.
