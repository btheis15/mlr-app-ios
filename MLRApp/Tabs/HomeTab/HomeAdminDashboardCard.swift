import SwiftUI

// MARK: - HomeAdminDashboardCard (web #339 / #351 / #353)
//
// An admin-only Home card (sits just below the House Hub card) that jumps to the
// admin dashboard, with a secondary "Alerts" quick-link straight to the
// broadcast composer. Self-hides for non-admins AND during "View as" preview
// (env.isAdmin already reads false while previewing).

struct HomeAdminDashboardCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.isAdmin {
            HStack(spacing: 10) {
                // Card body → the admin dashboard.
                NavigationLink { AdminView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.mlrScaled(20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Admin Dashboard").font(.mlrScaled(15, weight: .semibold)).foregroundStyle(.white)
                            Text("Members, committees, bookings & more")
                                .font(.mlrCaption).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Secondary Alerts quick-link → the broadcast composer (#351).
                NavigationLink { AdminAlertComposer() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "megaphone.fill").font(.mlrScaled(16, weight: .semibold))
                        Text("Alerts").font(.mlrScaled(11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 60)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.mlrPrimaryDark)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}
