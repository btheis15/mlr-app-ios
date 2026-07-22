import SwiftUI

// MARK: - FestDinnersView (weekly menu — web #318)
//
// The Dinners tab reads like a weekly menu: day · serving time · menu · head
// chef · houses on crew — all shown at once in one scrollable list, no
// tap-to-expand and no click-through. Crew-prep time/location are deliberately
// omitted (only the crew needs those; they live on FestDinnersDetailView, which
// stays for deep-links but nothing links to it). Chefs/crew keep an always-
// visible Edit button (FestDinnerEditSheet).

struct FestDinnersView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var currentUserId: UUID? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(env.festContentService.dinners) { dinner in
                    DinnerMenuCard(dinner: dinner, currentUserId: currentUserId)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color.mlrFestParchment)
        .navigationTitle("Weekly Menu")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if env.isSignedIn { currentUserId = await env.authService.userId }
        }
    }
}

// MARK: - Dinner menu card (full details inline)

private struct DinnerMenuCard: View {
    @Environment(AppEnvironment.self) private var env
    let dinner: FestDinner
    let currentUserId: UUID?
    @State private var showEditSheet = false

    /// Chef or an assigned crew member may edit (migration 0099).
    private var canEdit: Bool {
        guard env.isSignedIn, let uid = currentUserId else { return false }
        return dinner.chefUserId == uid || dinner.crewUserIds.contains(uid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: title + day/time + edit
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dinner.title)
                        .font(.festSerif(18, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Label(dinner.day, systemImage: "calendar")
                        Label(MLRFormat.time(dinner.time), systemImage: "clock")
                    }
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                }
                Spacer()
                if canEdit {
                    Button { showEditSheet = true } label: {
                        Text("✏️ Edit")
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(Color.mlrFest)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.mlrFest.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(Color.mlrFest.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Chef
            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.mlrScaled(11))
                Text(dinner.chef).font(.mlrScaled(13, weight: .medium))
            }
            .foregroundStyle(Color.mlrFestInk.opacity(0.8))

            // Menu lines
            if !dinner.menuLines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(dinner.menuLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.mlrFest.opacity(0.4)).frame(width: 5, height: 5).padding(.top, 6)
                            Text(line).font(.mlrScaled(14)).foregroundStyle(Color.mlrText)
                        }
                    }
                }
            }

            // Houses on crew (names only — prep time/location omitted by design)
            if env.isSignedIn && !dinner.crew.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.3.fill").font(.mlrScaled(11)).padding(.top, 1)
                    Text(dinner.crew.joined(separator: " · "))
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFestCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1))
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                FestDinnerEditSheet(dinner: dinner) {
                    await env.festContentService.reload()
                }
            }
        }
    }
}
