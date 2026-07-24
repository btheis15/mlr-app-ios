import SwiftUI

// MARK: - AdminView
// Admin hub — entry point to all admin sub-screens.

struct AdminView: View {
    @State private var showInvite = false

    var body: some View {
        List {
            Section("Members & Access") {
                // Per-member actions (make admin, assign house) live on individual profile
                // sheets in the People tab; this row is the directory + overview.
                adminLink(
                    destination: AdminMembersView(),
                    icon: "person.2.fill",
                    iconColor: Color.mlrPrimary,
                    title: "Members",
                    description: "Directory with emails · promote admins · edit a member's info"
                )

                adminLink(
                    destination: AdminHousesView(),
                    icon: "house.fill",
                    iconColor: Color.mlrAccent,
                    title: "Houses",
                    description: "Create houses and assign members"
                )

                adminLink(
                    destination: AdminCommitteesView(),
                    icon: "person.3.fill",
                    iconColor: Color.mlrInfo,
                    title: "Committees & Join Requests",
                    description: "Rosters and pending join request queue"
                )

                adminLink(
                    destination: AdminSignInsView(),
                    icon: "clock.arrow.circlepath",
                    iconColor: Color.mlrInfo,
                    title: "Recent Sign-Ins",
                    description: "See who has signed in and from where"
                )

                adminLink(
                    destination: PreviewAsView(),
                    icon: "eye.fill",
                    iconColor: Color.mlrWarning,
                    title: "Preview As",
                    description: "See the app as a member or a guest"
                )

                Button {
                    showInvite = true
                } label: {
                    adminRow(
                        icon: "envelope.badge.fill",
                        iconColor: Color.mlrPrimary,
                        title: "Invite People",
                        description: "Branded welcome email · signs them straight in"
                    )
                }
                .buttonStyle(.plain)
            }

            Section("Content & Moderation") {
                adminLink(
                    destination: AdminModerationView(),
                    icon: "shield.lefthalf.filled",
                    iconColor: Color.mlrDanger,
                    title: "Content Review",
                    description: "Review flagged posts and comments"
                )
            }

            Section("Alerts & Notifications") {
                adminLink(
                    destination: AdminCalloutsView(),
                    icon: "rectangle.stack.fill",
                    iconColor: Color.mlrFest,
                    title: "Home Callouts",
                    description: "Swipeable cards above the fest spotlight"
                )

                adminLink(
                    destination: AdminBroadcastComposer(),
                    icon: "megaphone.fill",
                    iconColor: Color.mlrAccent,
                    title: "Broadcast",
                    description: "Banner, Activity feed, and/or email — in one send"
                )

                adminLink(
                    destination: AdminScheduledBroadcasts(),
                    icon: "clock.badge.checkmark",
                    iconColor: Color.mlrInfo,
                    title: "Scheduled",
                    description: "Upcoming & recent scheduled broadcasts"
                )
            }

            Section("Bookings") {
                adminLink(
                    destination: AdminCabinBookings(),
                    icon: "house.lodge.fill",
                    iconColor: Color.mlrWarning,
                    title: "Cabin Bookings",
                    description: "Approve or deny cabin stay requests"
                )
                adminLink(
                    destination: AdminCabinDetails(),
                    icon: "house.lodge",
                    iconColor: Color.mlrPrimary,
                    title: "Cabins",
                    description: "Edit cabins, rooms, beds, and availability"
                )
            }

            Section("Tools") {
                adminLink(
                    destination: FamilyFestPlannerView(),
                    icon: "star.fill",
                    iconColor: Color.mlrFest,
                    title: "Family Fest Planner",
                    description: "Schedule, dinners, dues & payees — the master editor"
                )

                adminLink(
                    destination: AdminHelpContactView(),
                    icon: "phone.fill",
                    iconColor: Color.mlrAccent,
                    title: "Help Contact",
                    description: "Who the Help page says to text or call"
                )

                adminLink(
                    destination: AdminSystemView(),
                    icon: "server.rack",
                    iconColor: Color.mlrTextMuted,
                    title: "System",
                    description: "Media server status · pull latest & restart (owner)"
                )

                if let url = URL(string: "https://docs.google.com/forms/create") {
                    Link(destination: url) {
                        adminRow(
                            icon: "doc.text.fill",
                            iconColor: Color.mlrInfo,
                            title: "Create a Google Form",
                            description: "Survey, poll, or sign-up — then link it from a callout"
                        )
                    }
                }
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showInvite) {
            AdminInviteView()
        }
    }

    // MARK: - Row builders

    private func adminLink<D: View>(
        destination: D,
        icon: String,
        iconColor: Color,
        title: String,
        description: String
    ) -> some View {
        NavigationLink(destination: destination) {
            adminRow(icon: icon, iconColor: iconColor, title: title, description: description)
        }
    }

    private func adminRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.mlrScaled(18, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        AdminView()
    }
    .environment(AppEnvironment())
}
