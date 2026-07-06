import SwiftUI

// MARK: - AdminView
// Admin hub — entry point to all admin sub-screens.

struct AdminView: View {
    var body: some View {
        List {
            Section("Members & Access") {
                // Per-member admin actions (make admin, assign house, remove) now live on
                // each member's profile in the People tab — no separate Members list.
                adminLink(
                    destination: AdminHousesView(),
                    icon: "house.fill",
                    iconColor: Color.mlrAccent,
                    title: "Houses",
                    description: "Create houses and assign members"
                )

                adminLink(
                    destination: AdminSignInsView(),
                    icon: "clock.arrow.circlepath",
                    iconColor: Color.mlrInfo,
                    title: "Recent Sign-Ins",
                    description: "See who has signed in and from where"
                )
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

            Section("Communications") {
                adminLink(
                    destination: AdminAlertComposer(),
                    icon: "megaphone.fill",
                    iconColor: Color.mlrAccent,
                    title: "Post Announcement",
                    description: "Show a banner to all app visitors"
                )

                adminLink(
                    destination: AdminNotificationComposer(),
                    icon: "bell.badge.fill",
                    iconColor: Color.mlrPrimary,
                    title: "Send Notification",
                    description: "Broadcast to everyone or just admins"
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
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Admin link builder

    private func adminLink<D: View>(
        destination: D,
        icon: String,
        iconColor: Color,
        title: String,
        description: String
    ) -> some View {
        NavigationLink(destination: destination) {
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
}

#Preview {
    NavigationStack {
        AdminView()
    }
    .environment(AppEnvironment())
}
