import SwiftUI

// MARK: - SignInView
// Two-step passwordless sign-in: email entry → 8-digit OTP code entry.

struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .email
    @State private var email: String = ""
    @State private var code: String = ""

    // Resend cooldown
    @State private var resendSecondsLeft: Int = 0
    @State private var resendTimer: Timer? = nil

    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    private var auth: AuthService { env.authService }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Reassurance header
                    reassuranceHeader

                    Spacer().frame(height: 32)

                    switch step {
                    case .email:
                        emailStep
                    case .code:
                        codeStep
                    }

                    helpLink
                        .padding(.top, 32)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            // Pin the primary action button above the keyboard so it's always
            // reachable after typing — never hidden behind the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    switch step {
                    case .email:
                        primaryButton(
                            label: "Send Code",
                            isLoading: auth.isLoading,
                            isDisabled: email.trimmingCharacters(in: .whitespaces).isEmpty
                        ) {
                            Task { await sendCode() }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    case .code:
                        primaryButton(
                            label: "Verify Code",
                            isLoading: auth.isLoading,
                            isDisabled: code.count < 8
                        ) {
                            Task { await verifyCode() }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                }
                .background(.background)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn { dismiss() }
            }
        }
    }

    // MARK: - Reassurance header

    private var reassuranceHeader: some View {
        VStack(spacing: 6) {
            Image("brand-logo-green")
                .resizable()
                .scaledToFit()
                .frame(height: 56)

            Text("Just your name & email — no password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Step 1: Email

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter your email")
                    .font(.title2.bold())
                Text("We'll send you a one-time sign-in code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
                .submitLabel(.next)
                .focused($emailFocused)
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onAppear { emailFocused = true }
                .onSubmit { /* dismiss keyboard only — tap Send Code to submit */ }

            if let error = auth.error {
                errorBanner(error)
            }
        }
    }

    // MARK: - Step 2: OTP code

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter your code")
                    .font(.title2.bold())
                Text("We sent an 8-digit code to **\(email)**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Check your spam folder if you don't see it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("00000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: code) { _, newValue in
                    // Strip non-digits and cap at 8
                    let digits = newValue.filter(\.isNumber)
                    if digits.count > 8 {
                        code = String(digits.prefix(8))
                    } else {
                        code = digits
                    }
                }
                .onAppear { codeFocused = true }

            if let error = auth.error {
                errorBanner(error)
            }

            // Resend row
            HStack {
                Text("Didn't get it?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if resendSecondsLeft > 0 {
                    Text("Resend in \(resendSecondsLeft)s")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Resend code") {
                        Task { await resend() }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.mlrPrimary)
                    .disabled(auth.isLoading)
                }
            }

            // Back
            Button("← Use a different email") {
                cancelToEmailStep()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Help link

    private var helpLink: some View {
        NavigationLink {
            HelpView()
        } label: {
            Text("Need help signing in?")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .underline()
        }
    }

    // MARK: - Reusable sub-views

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func primaryButton(
        label: String,
        isLoading: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(label)
                        .font(.body.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .background(isDisabled ? Color(.systemGray4) : Color.mlrPrimary)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .disabled(isDisabled || isLoading)
    }

    // MARK: - Actions

    private func sendCode() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return }
        email = trimmed
        await auth.sendOTP(email: trimmed)
        if auth.error == nil {
            step = .code
            startResendCooldown()
        }
    }

    private func verifyCode() async {
        await auth.verifyOTP(email: email, token: code)
        if auth.isSignedIn {
            dismiss()
        }
    }

    private func resend() async {
        await auth.sendOTP(email: email)
        if auth.error == nil {
            code = ""
            startResendCooldown()
        }
    }

    private func cancelToEmailStep() {
        step = .email
        code = ""
        auth.error = nil
        stopResendTimer()
    }

    // MARK: - Resend cooldown

    private func startResendCooldown() {
        stopResendTimer()
        resendSecondsLeft = 30
        resendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if resendSecondsLeft > 0 {
                    resendSecondsLeft -= 1
                } else {
                    stopResendTimer()
                }
            }
        }
    }

    private func stopResendTimer() {
        resendTimer?.invalidate()
        resendTimer = nil
        resendSecondsLeft = 0
    }

    // MARK: - Step enum

    private enum Step {
        case email, code
    }
}

// HelpView now lives in MLRApp/Help/HelpView.swift (full Help & how-to screen).

#Preview {
    SignInView()
        .environment(AppEnvironment())
}
