import SwiftUI

// MARK: - "You're signed in — almost there"
//
// Migrations 0181–0184 locked down what an unverified account can SEE; 0213
// locked down what it can DO. Anyone can sign up with any email address, so a
// new account now sees only what a signed-out visitor sees, and every write RPC
// refuses it, until an admin confirms they're really family.
//
// ⚠️ WITHOUT THIS SCREEN the app is worse than useless to them: RLS returns
// fewer rows rather than an error, so they get the full member layout filled
// with empty lists, and every button fails with an unhelpful database message.
// They are locked out and cannot tell why.
//
// ⚠️ The DB column is `profiles.approved`; this UI says "verified". Deliberate —
// Supabase's email OTP already owns the word "verified" for the email address
// itself, and the two are genuinely different things.
//
// ⚠️ There is deliberately NOTHING to do here but wait. The copy says so
// explicitly, because an unactionable screen that looks like a form is worse
// than one that admits it's a waiting room.

struct AwaitingVerificationView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "hourglass")
                .font(.system(size: 44))
                .foregroundStyle(Color.mlrPrimary)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("You're signed in — almost there")
                    .font(.mlrScaled(20, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("An admin needs to confirm you're part of the family before the app opens up. There's nothing more to do on your end — we'll let you know.")
                    .font(.mlrScaled(14))
                    .foregroundStyle(Color.mlrTextMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            if let email = env.currentProfile?.email, !email.isEmpty {
                Text(email)
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.mlrCard)
                    .clipShape(Capsule())
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    Task { await env.loadProfile() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                        .font(.mlrScaled(15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.mlrPrimary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.pressable)

                Button("Sign out") {
                    Task { await env.signOut() }
                }
                .font(.mlrScaled(14, weight: .medium))
                .foregroundStyle(Color.mlrTextMuted)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlrSurface.ignoresSafeArea())
    }
}
