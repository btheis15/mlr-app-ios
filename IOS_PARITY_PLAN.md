# iOS Feature Parity + Visual Glow-Up — Work Plan

> Handoff doc. Nothing here has been implemented yet — this is the plan to
> execute in Xcode. Decisions already locked with the owner: **keep iOS dark
> mode** (polish both light + dark), and **Family Fest = "Rich Renaissance +
> modern polish."**

## Context

The MLR resort has two front-ends against **one shared Supabase backend**: the
web PWA (`mlr-app`, source of truth, now at migration **0108**) and this native
SwiftUI app (`mlr-app-ios`). The web app moved ahead through a run of recent
features — the cabin room/edit/email/self-pick chain (0092–0108), scheduled
broadcasts + reminders (0097–0103), callout completions + multi-link
(0093/0098), dinner crew self-edit (0099), and more — while iOS lags. Goal:
bring iOS to **full feature parity AND make it "top tier / better than web,"**
with the Family Fest section specifically no longer looking dull (better colors,
fonts, texture).

**Biggest simplifier:** the backend is already deployed. Every RPC below already
exists on the shared project. **No new Supabase migrations are required** — this
is Swift-side service wiring + new SwiftUI surfaces + a design pass.

## Guiding principles

1. **Reuse the existing seams.** Each web `lib/*.ts` seam maps to a Swift
   `Services/*Service.swift`. New RPCs get added there using the existing
   `Encodable` param-struct + `.rpc(...)` / `.from(...)` idiom (see
   `CabinService.swift`). New sheets build on `MLRSheet` + `fieldStyle`.
2. **Param names must match the SQL exactly** (`p_for_user`, `p_notify`,
   `p_room_ids`, `p_event_id`, `p_exclude_not_attending`, …). The web `lib/*.ts`
   files are the reference for every signature.
3. **Both palettes.** Every new color token is a `Color(light:dark:)` pair, per
   the `Colors.swift` doctrine (no translucent solid fills as card backgrounds).
4. **Graceful pre-migration degradation** mirrors web where it does it (low
   priority — prod DB is current).

---

## Workstream A — Design foundation (blocks B + the contrast sweep)

Files: `MLRApp/Shared/Design/{Colors,Typography,LiquidGlass}.swift`; Xcode project
(`project.pbxproj`) + `Info.plist`; asset catalog.

1. **Bundle the missing fonts (highest-impact fix — Fest identity is currently
   invisible).** Add `Cinzel-Regular.ttf`, `Cinzel-Bold.ttf`,
   `Yellowtail-Regular.ttf` (SIL OFL → App-Store safe) to the bundle; declare
   under `UIAppFonts` in the app target Info.plist **and the widget extension
   target**. Verify registered PostScript names (`UIFont.familyNames`) — Yellowtail
   often registers as `Yellowtail`, not `Yellowtail-Regular`; adjust
   `Font.script(_:)` accordingly. Today `Font.festSerif`/`Font.script` silently
   fall back to system, so ~45 `.festSerif(...)` sites render plain.
2. **Add missing color tokens** (light+dark) to `Colors.swift`: `mlrLake`,
   `mlrCampfire`, `mlrSun`, `mlrDusk` (Northwoods accent palette), `mlrFestInk`
   (sepia `#3a2a18` for Fest body), `mlrFestGold` (aged-gold heraldic accent),
   `mlrVenmo #3d95ce`, `mlrPaypal #003087`. **Fix `mlrAccent`** from dull chestnut
   `#804020` → campfire orange `#c2410c` (tasteful dark variant).
3. **Upgrade the card system** in `Typography.swift`: optional soft shadow on
   `cardStyle()` (the `WelcomeCard` recipe), and gradient/glass card helpers.
   Lean on the already-built `LiquidGlass.swift` (`glassCard`, only used ~4
   places today, designed for exactly these cards).
4. **Render the script wordmark** (`scriptStyle`) on Home hero and/or splash —
   defined but never called today.

## Workstream B — Family Fest visual redesign (owner priority)

Files: `MLRApp/Tabs/FamilyFestTab/*` (esp. `FestOverviewView`, `FestStatus`,
`FamilyFestSpotlight`, `FestScheduleView`, `FestDinnersView`, `FestPayView`).

- **Typography:** with Cinzel bundled, audit headings → Cinzel (uppercase,
  tracked), body → readable system font (web's `--font-display` rule).
- **Contrast fix:** Fest **body** text from wine-at-opacity → `mlrFestInk` sepia;
  reserve `mlrFest` wine for headings/accents; bump caption floor off
  `.tertiaryLabel`.
- **Heraldic + modern polish:** parchment-textured backgrounds, gradient hero
  banners (`campfire→sun→dusk`, or iOS-18 `MeshGradient`), aged-gold ornamental
  dividers, SF Symbol crest motifs, fest poster as hero, `glassCard` on
  day-section/info cards. Keep it distinctly "a season of the resort," not flat
  green chrome.
- **Motion:** `contentTransition(.numericText())` on the "Day N of N" counter +
  RSVP counts; `symbolEffect` on the live dot; `matchedGeometryEffect` /
  `.navigationTransition(.zoom)` card→detail hero morphs; `.scrollTransition`
  card entrances.

## Workstream C — Cabins parity (largest functional gap)

Files: `Services/CabinService.swift`, `Cabins/{CabinRequestSheet,EditCabinBookingSheet,CabinBookingsView}.swift`,
`AdminView.swift`; new `Cabins/PickMyRoomSheet.swift`, `Cabins/AdminCabinDetails.swift`.
Web refs: `lib/cabins.ts`, `components/{EditBookingSheet,PickMyRoomSheet,AdminCabinDetails,CabinRequestSheet}.tsx`.

1. **`set_booking_rooms(p_booking, p_room_ids)`** → add to `CabinService`. Then:
   - **Room reassignment** in `EditCabinBookingSheet` (today edits only
     dates/guests/notes via `admin_update_cabin_booking`): reuse `RoomPickRow`,
     force-show already-held rooms as available, call `set_booking_rooms`.
   - New **`PickMyRoomSheet`** (self-service; 0106 allows the requester): from
     `BookingRow` in `CabinBookingsView`, "Choose your room" when the booking has
     no rooms and its cabin uses named rooms.
2. **`AdminCabinDetails`** (new, Admin → Cabin requests → "Cabins"): cabin CRUD
   (name, room_count, bed_count, member-facing `notes`, `active` toggle) via
   direct `cabins` update + inline **`cabin_rooms` CRUD** (add/rename/beds/
   description/open-close/delete), per-row independent save like
   `CabinRoomsEditor`. Add a "Cabins" entry to `AdminView`.
3. **Book-on-behalf** — thread `p_for_user` through `requestStay(...)` + admin-only
   "Booking for" `MemberPickerSheet` in `CabinRequestSheet`; forUser path
   auto-approves via `reviewStay(..., notify)`.
4. **Email toggles** — `p_notify` on `reviewStay` (default true) + on
   `admin_update_cabin_booking` (default false); "Email them a confirmation"
   (`AdminCabinBookings` + forUser flow) and "Email them about this update"
   (`EditCabinBookingSheet`) checkboxes.
5. **"Not sure yet" checkbox** in `CabinRequestSheet` — skip room pick even when
   the cabin has rooms.

## Workstream D — Broadcasts & reminders parity

Files: `Services/NotificationsService.swift`, `Admin/{AdminAlertComposer,AdminNotificationComposer,AdminCalloutsView}.swift`,
`Events/EventComposer.swift`, `AdminView.swift`; new `Admin/AdminScheduledBroadcasts.swift`,
`Shared/Components/{ScheduleSendPicker,ReminderScheduler,EventTargetPicker}.swift`.
Web refs: `lib/{scheduledBroadcasts,eventTargeting}.ts`,
`components/{ScheduleSendPicker,ReminderScheduler,AdminScheduledBroadcasts,EventTargetPicker}.tsx`.

1. **Scheduled broadcasts** — add `schedule_broadcast(p_kind,p_payload,p_scheduled_at)`,
   `update_scheduled_broadcast(p_id,p_payload,p_scheduled_at)`,
   `cancel_scheduled_broadcast(p_id)` + a fetch-by-source query to
   `NotificationsService`. Shared **`ScheduleSendPicker`** ("Send now / Schedule
   for later" + datetime) into both admin composers (payload jsonb mirrors what
   each already collects). Build **`AdminScheduledBroadcasts`** queue (pending +
   sent/failed, realtime like `AdminCabinBookings`, per-row Edit/Cancel); add a
   "Scheduled" card to `AdminView`. (Send is pg_cron server-side — nothing to
   build there.)
2. **`ReminderScheduler`** — lists existing reminders for an item
   (`payload.sourceType+sourceId`) with status + Cancel, and an add form
   (relative offsets when an anchor exists — `events.start_time` /
   `home_callouts.deadline_at` — else custom datetime; title/body; callout-only
   "Skip anyone who marked this done" → `payload.excludeCalloutDone`). Mount in
   `EventComposer` (existing event; `start_time` already supported) + in
   `AdminCalloutsView` edit sheet (`deadline_at` already supported). Only when
   the item has a real id.
3. **Event targeting on `AdminAlertComposer`** — extract the notification
   composer's event-target UI into a shared `EventTargetPicker`, add to the
   banner composer (pass `p_event_id`/`p_exclude_not_attending`).

## Workstream E — Home + Feed parity

Files: `Tabs/HomeTab/{HomeView,HomeDelightCards}.swift`; `Tabs/FeedTab/{PostCard,CommentsView}.swift`;
`Services/PostsService.swift`.

1. **`OnThisDayCard`** — new self-hiding Home garnish: prior-year photo memory
   (±3 days of today's month-day) from Posts photos, members only. Reuse the
   SWR-cache + self-hide pattern of `WhosUpNorthCard`/`BirthdaysCard`.
2. **Post reactions "who reacted"** — bring chat's tap-to-expand-per-emoji
   reactor list to `PostCard`'s `reactionRow` ("You" for self).
3. **Post-comment edit + soft-delete** (listed, optional) — add chat's 24h
   author / admin-anytime edit + tombstone to `CommentsView` (verify
   `post_comments` update policy allows body edits; moderation guard blocks
   status, not body).

## Workstream F — Committees + Admin parity

Files: `Committees/{CommitteeDetailView,CommitteeMemberManageSheet}.swift`,
`Services/CommitteeService.swift`; `People/MemberSheetView.swift`, `AdminView.swift`;
new `Admin/AdminMembersView.swift`, `Admin/PreviewAsView.swift`.

1. **`set_my_committee_areas`** — member self-service "Your areas" editor (add/
   remove own areas, no lead, no approval); add RPC to `CommitteeService`.
2. **`leave_committee`** — add RPC + a "Leave committee" action for members.
3. **Admin member management gaps** — iOS does promote/remove-admin + delete only
   from `MemberSheetView`. Add the web's member directory admin view using
   `admin_members()` (returns house_id/house_name) + `admin_set_member_profile` +
   the `admin_override_status`/`request_admin_override`/`cancel_admin_override`
   flow. Surface as the "Members" admin sub-screen.
4. **Preview-As** (`PreviewAsView`) — device-local, UI-only role override (view as
   member/guest) + floating preview banner, mirroring web `/admin/preview`.
   Touches identity/guest resolution app-wide → its own careful sub-task.

## Workstream G — Minor parity items

- **Ask-for-Help GPS pin** — one-tap "use my location" (CoreLocation one-shot;
  today lat/long always nil); degrade gracefully if denied.
- **EventSheet per-day who's-coming** — add per-day roster for `day_rsvp` events;
  de-hardcode fest days (Sun–Sat) from the event's actual span.
- **Email-a-group visibility** — align with web (iOS gates admin-only) if wanted
  (low priority).

## Workstream H — Native "exceed web" polish + app-wide contrast sweep

Cross-cutting, after A–G:
- **Contrast sweep** (~40 views): Fest body → `mlrFestInk`; dull chestnut →
  `mlrCampfire`/`mlrAccent`; brand Venmo/PayPal pay rows (`FestPayView`,
  `MemberSheetView`, `PeopleDirectoryView`); gradient + shadow on
  spotlight/callout/home canvas.
- **Native delight:** broaden `Haptics`/`.sensoryFeedback` (callout swipe, poll
  vote, pay tap); `matchedGeometryEffect` hero transitions; `symbolEffect` /
  `contentTransition(.numericText())` on counters/badges; `.scrollTransition`
  entrances; `TipKit` for the callout-swipe hint (web's `.callout-wiggle`);
  `matchedGeometry` splash→header logo hand-off to match web's FLIP.
- **FestStatus live-week inline edit** (also a functional gap): add the chef/crew
  self-edit + full admin edit affordance web's `TodayEvent`/`TodayDinner` gained
  (0099) — reuse the iOS `FestDinnerEditSheet`/`FestInlineEditSheets` already
  wired into the Overview accordion.

---

## Verification (build/test in Xcode)

1. `open "MLR App.xcodeproj"`, resolve SPM packages, **Build** (⌘B) — fix compile
   errors. (Watch for new Swift files not added to target membership, and
   `UIAppFonts` present in **both** app + widget targets.)
2. Run on simulator + a device added to Home Screen (push/PWA-parity flows need a
   real standalone install).
3. Screen-by-screen smoke test by workstream:
   - **Cabins:** request with rooms / "Not sure yet"; admin approve with/without
     email; edit booking rooms; self-service "Choose your room"; cabin+room CRUD.
   - **Broadcasts:** schedule an alert + a notification; see it in the queue;
     edit/cancel; add an event reminder + a callout reminder.
   - **Home:** OnThisDay shows a matching old photo; post reactions expand.
   - **Committees:** add/remove your own areas; leave a committee; admin edit a
     member; Preview-As member/guest.
   - **Family Fest:** Cinzel renders; parchment/gradients/gold read richly in
     **both** light and dark; live-week cards editable.
4. Verify **light AND dark** on every redesigned screen.

## Sequencing / commit strategy

All work on branch **`claude/ios-feature-parity-2kzc2x`**. Commit per workstream
with clear messages; suggested order: **A → B → C → D → E → F → G → H** (A and B
front-loaded: A unblocks the visual work, B is the owner's stated priority). Open
a **draft PR** on `btheis15/mlr-app-ios` after the first substantive push. Update
the iOS repo's own docs as features land.

---

### Reference — confirmed iOS gaps vs. web (parity diff summary)

**Missing on iOS (verified — no references in the Swift source):**
`set_booking_rooms`, `AdminCabinDetails` (cabin/room CRUD), cabin `p_for_user`,
cabin `p_notify` toggles, cabin "Not sure yet", `schedule_broadcast` /
`AdminScheduledBroadcasts` / `ScheduleSendPicker`, `ReminderScheduler`, event
targeting on the alert banner, Home `OnThisDayCard`, post reactions who-reacted,
`set_my_committee_areas`, `leave_committee`, admin `admin_set_member_profile` /
`admin_override_status`, Preview-As, Ask-for-Help GPS pin, EventSheet per-day
who's-coming, FestStatus live-week inline edit.

**Already present on iOS (do NOT rebuild):** full committee & house chat (edit/
delete/reactions-who-reacted/mentions), content moderation (report +
`AdminModerationView`), polls, events + day-RSVP, WelcomeIntro onboarding, help
contact (`resort_config`), announcements banner, notif/push prefs (full sets),
Fest dues per-day calculator, Fest inline editing from Overview/detail, chef/crew
self-edit (`FestDinnerEditSheet`), callout multi-link + "mark done" completions,
work-item urgency/media/comments/edit, house calendar/hub/stays, invite emails,
MJT house dues.

**iOS-only superpowers already shipped (the "better than web" base to build on):**
App Intents / Siri (20 files), Live Activities (Fest + Help), home/lock-screen
widgets + Control Center, WeatherKit, on-device Apple Intelligence
(FoundationModels: chat "Catch me up", AI event descriptions, AI help
suggestions), CoreSpotlight indexing, EventKit/Contacts/Maps/Messages/ApplePay
bridges, Kingfisher image caching, Liquid Glass design system, global search.
