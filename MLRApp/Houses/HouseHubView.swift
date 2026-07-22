import SwiftUI

// MARK: - HouseHubView
// One place for everything about a member's house: its calendar (who's staying
// and when), its chat, and its work-item to-do list. Since a member belongs to
// exactly one house, this is reached from the House Hub card on Home. Mirrors the
// web app's /house hub.

struct HouseHubView: View {
    @Environment(AppEnvironment.self) private var env

    let house: House

    @State private var stays: [HouseStay] = []
    @State private var loading = true
    @State private var showRulesEditor = false
    // Locally reflects a just-saved edit without re-navigating (the passed-in
    // `house` is immutable); falls back to the house's stored rules.
    @State private var rulesOverride: String? = nil

    private var today: String { HouseStay.iso.string(from: .now) }
    private var upcoming: [HouseStay] { stays.filter { !$0.isPast(today) } }
    private var rules: String { rulesOverride ?? house.rules }

    // Shared minimum height for the three full-width hub cards (calendar, chat,
    // rules) so they line up cleanly. The rules card can still grow past this
    // once it holds text.
    private let hubCardMinHeight: CGFloat = 101

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(house.emoji) \(house.name)").font(.mlrScaled(24, weight: .bold))
                    if !house.description.isEmpty {
                        Text(house.description).font(.mlrBody).foregroundStyle(Color.mlrTextMuted)
                    }
                }

                // MJT House dues reminder — self-hides for other houses and outside the fest window.
                MjtHouseDuesCard(house: house)

                // ── Calendar & chat — the two primary destinations, 2-up (#359) ──
                SectionLabel(text: "Calendar & chat")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    NavigationLink(destination: HouseCalendarView(house: house)) {
                        HomeTile(icon: "calendar", title: "Calendar",
                                 subtitle: "Who's up & when", tint: Color.mlrPrimary,
                                 fullWidth: false, minHeight: hubCardMinHeight)
                    }
                    .buttonStyle(.plain)
                    NavigationLink(destination: HouseChatView(house: house, assumeMember: true)) {
                        HomeTile(icon: "bubble.left.and.bubble.right.fill", title: "House chat",
                                 subtitle: "Talk to your house", tint: Color.mlrInfo,
                                 fullWidth: false, minHeight: hubCardMinHeight)
                    }
                    .buttonStyle(.plain)
                }
                if !loading {
                    Text(calSubtitle).font(.mlrCaption).foregroundStyle(Color.mlrTextMuted).padding(.horizontal, 4)
                }

                // ── House — the shared rules doc ──
                SectionLabel(text: "House")

                // House Rules — a shared, editable open-text doc (any member).
                Button {
                    showRulesEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.portrait.fill")
                                .font(.mlrScaled(18, weight: .semibold))
                                .foregroundStyle(Color.mlrAccent)
                            Text("House Rules")
                                .font(.mlrScaled(15, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                            Spacer()
                            Image(systemName: "square.and.pencil")
                                .font(.mlrScaled(13, weight: .semibold))
                                .foregroundStyle(Color.mlrTextSubtle)
                        }
                        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            Text("No house rules yet — tap to add.")
                                .font(.mlrCaption)
                                .foregroundStyle(Color.mlrTextMuted)
                        } else {
                            Text(rules)
                                .font(.mlrBody)
                                .foregroundStyle(Color.mlrText)
                                .lineLimit(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: hubCardMinHeight, alignment: .leading)
                    .cardStyle()
                }
                .buttonStyle(.plain)

                // Who's staying lives on the House calendar (surfaced via the
                // "Next up:" line on the calendar card above) — no separate
                // preview here, matching web (#248).

                // ── To-do (the checklist also shows resort-wide MLR items) ──
                SectionLabel(text: "To-do")
                WorkChecklistCard()
            }
            .padding(16)
        }
        .background(Color.mlrSurface)
        .navigationTitle(house.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            stays = await env.housesService.fetchStays(houseId: house.id)
            loading = false
        }
        .sheet(isPresented: $showRulesEditor) {
            HouseRulesEditor(houseId: house.id, initial: rules) { saved in
                rulesOverride = saved
            }
        }
    }

    private var calSubtitle: String {
        if loading { return "Who's going up to the house and when." }
        if let next = upcoming.first {
            return "Next up: \(next.label) · \(next.dateRangeLabel)"
        }
        return "No stays yet — add when you're going up."
    }
}

// MARK: - HouseHubHomeCard
// Home entry that opens the House Hub. Self-hides for guests and members not in a
// house, so it only appears for the people it's for. Sits high on Home since many
// people are focused on their house most of the year.

struct HouseHubHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Read the member's house from the observed service value (resolved when the
        // profile loads, in AppEnvironment.refreshMyHouse). Gating in rendered content
        // is a reliably-tracked dependency, so the card appears as soon as it's set —
        // unlike a per-view .task(id: currentProfile?.houseId), which didn't re-render.
        Group {
            if let house = env.housesService.myHouse {
                NavigationLink(destination: HouseHubView(house: house)) {
                    HStack(spacing: 12) {
                        Text(house.emoji)
                            .font(.mlrScaled(24))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(house.name).font(.mlrScaled(15, weight: .semibold)).foregroundStyle(.white)
                            Text("Your house — calendar, chat & to-do list")
                                .font(.mlrCaption).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.mlrScaled(14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(14)
                    .background(Color.mlrPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - HouseRulesEditor
// A plain open-text editor for a house's shared rules doc. Any house member can
// save (gated server-side by set_house_rules → is_house_member, migration 0072).

private struct HouseRulesEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let houseId: UUID
    let onSaved: (String) -> Void

    @State private var draft: String
    @State private var saving = false
    @State private var errorText: String?

    init(houseId: UUID, initial: String, onSaved: @escaping (String) -> Void) {
        self.houseId = houseId
        self.onSaved = onSaved
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.mlrBody)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(Color.mlrSurface)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Add your house rules — anything goes. e.g. quiet hours, who feeds the dog, cabin close-up checklist…")
                                .font(.mlrBody)
                                .foregroundStyle(Color.mlrTextSubtle)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
                if let errorText {
                    Text(errorText)
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .background(Color.mlrSurface)
            .navigationTitle("House Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            try await env.housesService.saveHouseRules(houseId: houseId, rules: draft)
            onSaved(draft)
            dismiss()
        } catch {
            errorText = "Couldn't save. Check your connection and try again."
            print("[HouseRulesEditor] save error: \(error)")
        }
    }
}
