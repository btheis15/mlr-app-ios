import Foundation
import Supabase

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
