import Foundation
import Supabase

// MARK: - App Review access
//
// Apple's reviewer cannot receive our emailed one-time code, so a single
// designated review account signs in with an embedded password instead of a
// real OTP. When this email is used:
//   • no code email is sent (no member is emailed or notified), and
//   • the fixed `code` below is exchanged for a normal password session.
// The account is also hidden from the People directory (see PeopleDirectoryView).
//
// SETUP: create this user in Supabase Auth with exactly `password` below, and a
// `profiles` row with include_in_directory = false. Rotate the code/password or
// delete the account after the app is approved.
enum ReviewAccess {
    /// The reviewer signs in with this email.
    static let email = "appreview@muskellungelakeresort.com"
    /// The fixed 8-digit "code" the reviewer types on the code screen.
    static let code = "77341902"
    /// Password of the Supabase review user (must match the dashboard).
    static let password = "Mlr!Review-2026-x9Kp3qL"

    /// True when `input` is the review account's email (case/space-insensitive).
    static func isReviewEmail(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
    }
}

// MARK: - AuthService

@Observable
@MainActor
final class AuthService {
    var isSignedIn: Bool = false
    var isLoading: Bool = false
    var error: String? = nil

    /// Set to true to trigger the sign-in sheet presentation.
    /// Observed by the root view (or sheet host) to present `SignInView`.
    var showSignIn: Bool = false

    // MARK: - Computed

    /// The current user's UUID, or nil when signed out.
    var userId: UUID? {
        get async {
            try? await supabase.auth.session.user.id
        }
    }

    // MARK: - Sign-in sheet trigger

    /// Signals that the sign-in sheet should be presented.
    /// RootView (or any sheet host) should observe `showSignIn` and present `SignInView`.
    func promptSignIn() {
        showSignIn = true
    }

    // MARK: - Session restore

    /// Call once on app launch to re-hydrate an existing Supabase session.
    func restoreSession() async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await supabase.auth.session
            isSignedIn = true
        } catch {
            // No valid session on disk — stay signed out, not an error.
            isSignedIn = false
        }
    }

    // MARK: - OTP flow

    /// Step 1 — send a one-time code to `email`.
    func sendOTP(email: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        // App Review account: send nothing (no email, no member notified) and let
        // the UI advance to the code screen where the fixed review code is entered.
        if ReviewAccess.isReviewEmail(email) {
            print("[AuthService] review account — skipping OTP email")
            return
        }
        do {
            try await supabase.auth.signInWithOTP(
                email: email,
                shouldCreateUser: true
            )
            print("[AuthService] sendOTP succeeded for \(email)")
        } catch {
            print("[AuthService] sendOTP raw error: \(error)")
            self.error = friendlyAuthError(error)
        }
    }

    /// Step 2 — verify the 8-digit OTP code the user received.
    /// Sets `isSignedIn = true` on success.
    func verifyOTP(email: String, token: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        print("[AuthService] verifyOTP called — email: \(email), token length: \(token.count)")
        // App Review bypass: exchange the fixed review code for a password session.
        if ReviewAccess.isReviewEmail(email) {
            guard token == ReviewAccess.code else {
                self.error = "Code invalid or expired — tap Resend to get a new one."
                return
            }
            do {
                try await supabase.auth.signIn(email: ReviewAccess.email, password: ReviewAccess.password)
                print("[AuthService] review account SUCCESS")
                isSignedIn = true
                showSignIn = false
            } catch {
                print("[AuthService] review account FAILED — raw: \(error)")
                self.error = friendlyAuthError(error)
            }
            return
        }
        do {
            try await supabase.auth.verifyOTP(
                email: email,
                token: token,
                type: .email
            )
            print("[AuthService] verifyOTP SUCCESS")
            isSignedIn = true
            showSignIn = false  // dismiss the sheet immediately, not via onChange
        } catch {
            print("[AuthService] verifyOTP FAILED — raw: \(error)")
            print("[AuthService] verifyOTP FAILED — localizedDescription: \(error.localizedDescription)")
            self.error = friendlyAuthError(error)
        }
    }

    // MARK: - Change login email

    /// Start a self-serve login-email change. Supabase sends a confirmation link
    /// to the new address; the change takes effect once confirmed.
    func changeEmail(to newEmail: String) async throws {
        try await supabase.auth.update(user: UserAttributes(email: newEmail))
    }

    // MARK: - Sign out

    func signOut() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // .local clears only this device's session; other browsers/devices stay signed in.
            try await supabase.auth.signOut(scope: .local)
        } catch {
            // Log but don't surface — always clear local state.
            print("[AuthService] signOut error: \(error)")
        }
        isSignedIn = false
        self.error = nil
    }

    // MARK: - Error mapping

    private func friendlyAuthError(_ error: Error) -> String {
        // Check typed Supabase AuthError first — errorCode is reliable.
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .otpExpired:
                return "Code expired — tap Resend to get a new one."
            case .overRequestRateLimit, .overEmailSendRateLimit:
                return "Too many attempts. Please wait a minute and try again."
            case .userNotFound:
                return "No account found for that email. Check the address and try again."
            default:
                // Surface the actual Supabase message for any unrecognized code.
                let msg = authError.message
                let code = authError.errorCode.rawValue
                if msg.lowercased().contains("otp") || code.contains("otp") {
                    return "Code invalid or expired — tap Resend to get a new one."
                }
                return "\(msg) (\(code))"
            }
        }

        // Fallback for non-AuthError (e.g. network errors).
        let raw = error.localizedDescription.lowercased()
        if raw.contains("network") || raw.contains("internet") || raw.contains("offline")
            || raw.contains("could not connect") {
            return "No internet connection. Check your signal and try again."
        }
        return "Sign-in error: \(error.localizedDescription)"
    }
}
