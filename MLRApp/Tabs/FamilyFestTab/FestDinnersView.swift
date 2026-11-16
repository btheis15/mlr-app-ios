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
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(env.festContentService.dinners) { dinner in
                    DinnerMenuCard(dinner: dinner)
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
            // Refreshes the cached can_edit_fest flag the pencil rule reads.
            if env.isSignedIn && !env.isPreviewing { _ = await env.festContentService.canEditFest() }
        }
    }
}

// MARK: - Dinner menu card (full details inline)

private struct DinnerMenuCard: View {
    @Environment(AppEnvironment.self) private var env
    let dinner: FestDinner
    @State private var showEditSheet = false

    /// Web's rule: a full editor, or this dinner's chef/crew (migration 0099).
    /// Hidden while previewing as another member. Always the current year.
    private var canEdit: Bool {
        env.canEditFestDinner(chefUserId: dinner.chefUserId, crewUserIds: dinner.crewUserIds)
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
                    // Full editors get the whole dinner editor; chef/crew get the
                    // operational details (FestDinnerEditSheet decides).
                    FestEditPencil(label: "dinner") { showEditSheet = true }
                        .padding(.top, -8).padding(.trailing, -8)
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
            FestDinnerEditSheet(dinner: dinner) { await env.festContentService.reload() }
        }
    }
}
