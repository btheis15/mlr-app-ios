import SwiftUI
import Supabase

// MARK: - AdminHelpContactView
// Admin editor for the Help page's human escape-hatch contact — name, phone,
// and email stored in the `resort_config` singleton (migration 0082). Reads
// are public (the help contact is itself the sign-in escape hatch so it can't
// be gated); writes are admin-only enforced by RLS.
// Mirrors web /admin/help-contact + AdminHelpContact component.

struct AdminHelpContactView: View {
    @Environment(AppEnvironment.self) private var env

    struct Values: Equatable {
        var name = ""
        var phone = ""
        var email = ""
    }

    @State private var draft = EditorDraft(Values())
    @State private var seeded = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var phoneValid: Bool {
        let p = draft.value.phone.trimmingCharacters(in: .whitespaces)
        return p.isEmpty || PhoneFormat.normalize(p) != nil
    }
    private var emailValid: Bool {
        let e = draft.value.email.trimmingCharacters(in: .whitespaces)
        return e.isEmpty || e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        Form {
            Section {
                EditorTextField("Name", text: $draft.value.name, placeholder: "e.g. Pat", limit: 60)
                EditorTextField("Phone", text: $draft.value.phone, placeholder: "Any format, e.g. 715 453 3130",
                                keyboard: .phonePad, autocapitalize: false)
                if !phoneValid {
                    Text("That doesn\u{2019}t look like a real phone number.")
                        .font(.caption).foregroundStyle(Color.mlrDanger)
                }
                EditorTextField("Email", text: $draft.value.email, placeholder: "you@email.com",
                                keyboard: .emailAddress, autocapitalize: false)
                if !emailValid {
                    Text("That doesn\u{2019}t look like an email address.")
                        .font(.caption).foregroundStyle(Color.mlrDanger)
                }
            } header: {
                Text("Help page contact")
            } footer: {
                Text("Phone in any format; it is saved in international form. Who the Help page says to text or call when someone is stuck. Leave all blank and the Help page just says to ask a family admin.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage {
                EditorErrorBanner(message: errorMessage) { Task { await save() } }
            }
        }
        .navigationTitle("Help Contact")
        .navigationBarTitleDisplayMode(.large)
        .editorUnsavedGuard(isDirty: draft.isDirty)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!draft.isDirty || !phoneValid || !emailValid)
                }
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draft = EditorDraft(Values(name: env.helpContactName, phone: env.helpContactPhone,
                                       email: env.helpContactEmail))
        }
    }

    private func save() async {
        guard !saving, draft.isDirty, phoneValid, emailValid else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        let v = draft.value
        let name = v.name.trimmingCharacters(in: .whitespaces)
        let rawPhone = v.phone.trimmingCharacters(in: .whitespaces)
        let phone = rawPhone.isEmpty ? "" : (PhoneFormat.normalize(rawPhone)?.e164 ?? rawPhone)
        let email = v.email.trimmingCharacters(in: .whitespaces)
        do {
            // The columns are NOT NULL DEFAULT '' (migration 0082): blank is "",
            // never null. resort_config has a single row (boolean id, default true).
            let params: [String: AnyJSON] = [
                "help_contact_name":  .string(name),
                "help_contact_phone": .string(phone),
                "help_contact_email": .string(email),
            ]
            try await supabase
                .from("resort_config")
                .upsert(params, onConflict: "id")
                .execute()
            env.helpContactName  = name
            env.helpContactPhone = phone
            env.helpContactEmail = email
            draft = EditorDraft(Values(name: name, phone: phone, email: email))
            Haptics.success()
        } catch {
            errorMessage = "Couldn\u{2019}t save. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}
