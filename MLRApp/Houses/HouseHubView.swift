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

    private var today: String { HouseStay.iso.string(from: .now) }
    private var upcoming: [HouseStay] { stays.filter { !$0.isPast(today) } }

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

                // Calendar
                NavigationLink(destination: HouseCalendarView(house: house)) {
                    HomeTile(
                        icon: "calendar",
                        title: "House calendar",
                        subtitle: calSubtitle,
                        tint: Color.mlrPrimary,
                        fullWidth: true
                    )
                }
                .buttonStyle(.plain)

                // Chat
                NavigationLink(destination: HouseChatView(house: house, assumeMember: true)) {
                    HomeTile(
                        icon: "bubble.left.and.bubble.right.fill",
                        title: "House chat",
                        subtitle: "Talk with everyone in your house.",
                        tint: Color.mlrInfo,
                        fullWidth: true
                    )
                }
                .buttonStyle(.plain)

                // Upcoming stays preview
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who's staying").font(.mlrScaled(15, weight: .bold))
                        ForEach(upcoming.prefix(3)) { s in
                            NavigationLink(destination: HouseCalendarView(house: house)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.label).font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrText)
                                    Text(s.headCount > 1 ? "\(s.dateRangeLabel) · \(s.headCount) people" : s.dateRangeLabel)
                                        .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).cardStyle()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // To-do list (the checklist also shows resort-wide MLR items).
                VStack(alignment: .leading, spacing: 8) {
                    Text("To-do list").font(.mlrScaled(15, weight: .bold))
                    WorkChecklistCard()
                }
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
    @State private var house: House?

    var body: some View {
        Group {
            if let house {
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
        .task(id: env.currentProfile?.houseId) {
            if let hid = env.currentProfile?.houseId {
                house = await env.housesService.house(withId: hid)
            } else {
                house = nil
            }
        }
    }
}
