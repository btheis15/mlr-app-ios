# iOS compatibility (min iOS 18)

The app is built against the latest iOS SDK but must run on **iOS 18+**
(iPhone XS / 2018 and newer). Liquid Glass and other iOS‑26 niceties are used
**only when available**, with graceful fallbacks below.

## Rules for iOS‑26‑only APIs
- **Liquid Glass**: never call `.glassEffect` / `Glass` / `.buttonStyle(.glass)`
  directly in a view. Use the gated helpers in `Shared/Design/LiquidGlass.swift`
  (`.glassPrimary`, `.glassSecondary`, `.glassFest`, `.glassCircle`, `.glassCard`).
  Each branches on `if #available(iOS 26.0, *)` and renders a solid/material
  fallback below 26. If you need glass somewhere new, add another gated helper —
  don't inline it.
- Any other iOS‑26 (or 18.4+) API must be wrapped in `if #available` with a
  fallback, or not used.
- **On‑device AI (FoundationModels) is intentionally NOT used** — it's iOS‑26‑only
  and was removed. Don't reintroduce `import FoundationModels`, `LanguageModelSession`,
  `@Generable`, etc.
- **Don't conform App Intents entities to `IndexedEntity`** — its default
  protocol witnesses (`hideInSpotlight`) resolve to iOS‑26 symbols and **crash at
  launch on iOS 18** (the compiler does NOT catch this). Spotlight indexing is
  done via hand‑built `CSSearchableItem`s in `ContentIndexer` instead.

## The compiler catches most things — but not all
Building with the deployment target at iOS 18 turns any *unguarded* too‑new API
into a build error (unguarded‑availability is set aggressive). The exception is
**protocol‑conformance default witnesses** from a newer SDK (like the
`IndexedEntity` case): they compile clean and only crash at launch on the older
OS. So a green build is necessary but not sufficient.

## Pre‑release verification checklist
1. Set the run destination to an **iOS 18 simulator** (or a real iOS 18 device)
   and build the **MLR App** scheme — must be green.
2. **Launch** it. Watch the console for `dyld: Symbol not found: …` (a missing
   iOS‑26 symbol). If you see one, gate or remove that API.
3. Sign in and visit every surface, watching for crashes / broken layout:
   Home, Feed + a chat, Family Fest (Schedule / Dinners / Pay / Photos),
   Events + an event sheet, Committees + a committee chat, Cabins + the booking
   sheet, People + a member sheet, Help, Work Checklist, Profile / Admin.
4. Confirm the **glass fallback** looks right (buttons/cards have solid
   backgrounds, nothing invisible) — this is the below‑26 path.
5. On an **iOS 26** device/sim, confirm the real Liquid Glass renders (the
   above‑26 path).
