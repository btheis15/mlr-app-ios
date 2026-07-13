import SwiftUI
import Supabase

// MARK: - WelcomeIntroView
// Two-step onboarding sheet shown once to brand-new members whose
// profiles.intro_seen == false and whose profile is sparse (name + email only).
// Step 1: collect phone, birthday, payment handle.
// Step 2: explain push notifications, embed PushToggleView, mark intro done.

struct WelcomeIntroView: View {
    @Environment(AppEnvironment.self) private var env

    // Drives the PageTabView — 0 = welcome/collect, 1 = push prefs
    @State private var currentStep: Int = 0

    // Step 1 fields
    @State private var phone: String = ""
    @State private var birthday: Date = Calendar.current.date(
        from: DateComponents(year: 1990, month: 1, day: 1)
    ) ?? .now
    @State private var birthdaySet: Bool = false
    @State private var venmo: String = ""
    @State private var zelle: String = ""
    @State private var appleCash: String = ""

    // Step 2 state
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    @FocusState private var phoneFocused: Bool

    private var profile: Profile? { env.currentProfile }

    var body: some View {
        TabView(selection: $currentStep) {
            // ── Step 1: notifications first ─────────────────────────
            pushStepView
                .tag(0)

            // ── Step 2: profile basics ──────────────────────────────
            basicsStepView
                .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut, value: currentStep)
        .interactiveDismissDisabled(true) // must complete intro
        .onAppear {
            if let p = profile {
                phone      = p.phone ?? ""
                venmo      = p.venmoHandle ?? ""
                zelle      = p.zelleHandle ?? ""
                appleCash  = p.appleCashHandle ?? ""
                if let bdStr = p.birthday,
                   let bd = isoDateFormatter.date(from: bdStr) {
                    birthday    = bd
                    birthdaySet = true
                }
            }
        }
    }

    // MARK: - Step 1: Welcome + collect basics

    private var basicsStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Hero
                VStack(spacing: 8) {
                    Image("brand-logo-green")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 64)
                        .frame(maxWidth: .infinity)

                    Text("A few details about you")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)

                    Text("So the family can reach you — your phone, birthday, and how you like to get paid back. All optional.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 8)

                // Phone
                formSection(title: "Phone (optional)") {
                    TextField("(715) 555-0100", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($phoneFocused)
                        .fieldStyle()
                }

                // Birthday
                formSection(title: "Birthday (optional)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if birthdaySet {
                            HStack {
                                Text(birthday.formatted(.dateTime.month(.wide).day().year()))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button("Clear") {
                                    birthdaySet = false
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Button("Add birthday") {
                                birthdaySet = true
                            }
                            .foregroundStyle(Color("primary"))
                        }

                        if birthdaySet {
                            DatePicker(
                                "Birthday",
                                selection: $birthday,
                                in: ...Date.now,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                        }
                    }
                }

                // Payment handles
                formSection(title: "Preferred payment (optional)",
                            subtitle: "So family can reimburse or pay you easily.") {
                    VStack(spacing: 10) {
                        paymentField(icon: "v.circle.fill",
                                     color: .blue,
                                     placeholder: "Venmo @handle",
                                     text: $venmo)
                        paymentField(icon: "z.circle.fill",
                                     color: .purple,
                                     placeholder: "Zelle email or phone",
                                     text: $zelle)
                        paymentField(icon: "applelogo",
                                     color: .primary,
                                     placeholder: "Apple Cash handle",
                                     text: $appleCash)
                    }
                }

                // Done — save basics and finish onboarding
                Button {
                    Task { await finishOnboarding() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Done — take me to the resort")
                                .font(.body.bold())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .background(Color("primary"))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(isSaving)
                .padding(.top, 8)

                Button {
                    withAnimation { currentStep = 0 }
                } label: {
                    Text("← Back")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }

                stepIndicator(active: 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Step 2: Push notification explanation + prefs

    private var pushStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .font(.mlrScaled(48))
                        .foregroundStyle(Color("primary"))
                        .frame(maxWidth: .infinity)

                    Text("Welcome to MLR!")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)

                    Text("First, turn on notifications so you get a heads-up on your phone for what matters Up North — event RSVPs, dinners, help requests, and emergencies. You can change these anytime in Profile → Notifications.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 8)

                // Embedded push prefs — uses the real PushToggleView
                PushToggleView()

                // Continue to profile basics
                Button {
                    withAnimation { currentStep = 1 }
                } label: {
                    Text("Continue")
                        .font(.body.bold())
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .background(Color("primary"))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Button {
                    withAnimation { currentStep = 1 }
                } label: {
                    Text("Skip for now")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                stepIndicator(active: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Sub-views

    private func formSection<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func paymentField(
        icon: String,
        color: Color,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stepIndicator(active: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(i == active ? Color("primary") : Color(.systemGray4))
                    .frame(width: i == active ? 20 : 8, height: 8)
                    .animation(.easeInOut, value: active)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    /// Final step: persist the collected basics, then mark the intro seen so the
    /// sheet dismisses. Both are non-blocking — the user is never stuck.
    private func finishOnboarding() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        await saveBasics()
        await markIntroSeen()
    }

    private func saveBasics() async {
        guard let userId = await env.authService.userId else { return }

        let birthdayStr = birthdaySet
            ? isoDateFormatter.string(from: birthday)
            : nil

        let params: [String: AnyJSON] = [
            "phone":             phone.isEmpty  ? .null : .string(phone),
            "birthday":          birthdayStr == nil ? .null : .string(birthdayStr!),
            "venmo_handle":      venmo.isEmpty  ? .null : .string(venmo),
            "zelle_handle":      zelle.isEmpty  ? .null : .string(zelle),
            "apple_cash_handle": appleCash.isEmpty ? .null : .string(appleCash)
        ]

        do {
            try await supabase
                .from("profiles")
                .update(params)
                .eq("id", value: userId.uuidString)
                .execute()
            await env.loadProfile()
        } catch {
            // Non-blocking — let them proceed even if the update fails.
            print("[WelcomeIntroView] saveBasics error: \(error)")
        }
    }

    private func markIntroSeen() async {
        do {
            try await supabase
                .rpc("mark_intro_seen")
                .execute()
            env.currentProfile?.introSeen = true
        } catch {
            saveError = "Couldn't save — you can finish setup in Profile."
            // Still dismiss so the user isn't stuck.
            env.currentProfile?.introSeen = true
            print("[WelcomeIntroView] markIntroSeen error: \(error)")
        }
    }
}

private let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

#Preview {
    WelcomeIntroView()
        .environment(AppEnvironment())
}
