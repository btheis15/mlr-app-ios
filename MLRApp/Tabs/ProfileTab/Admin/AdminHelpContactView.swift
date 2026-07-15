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
    @State private var name:  String = ""
    @State private var phone: String = ""
    @State private var email: String = ""
    @State private var saving = false
    @State private var saveMessage: String? = nil

    private var isDirty: Bool {
        name  != env.helpContactName ||
        phone != env.helpContactPhone ||
        email != env.helpContactEmail
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Brian", text: $name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Phone") {
                    TextField("+17155551234", text: $phone)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.phonePad)
                }
                LabeledContent("Email") {
                    TextField("you@email.com", text: $email)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Help page contact")
            } footer: {
                Text("Phone in E.164 format (+1…). Who the Help page says to text or call when someone is stuck.")
            }

            if let msg = saveMessage {
                Section {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(msg.hasPrefix("Saved") ? Color.mlrPrimary : Color.mlrDanger)
                }
            }
        }
        .navigationTitle("Help Contact")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(!isDirty || saving)
            }
        }
        .onAppear {
            name  = env.helpContactName
            phone = env.helpContactPhone
            email = env.helpContactEmail
        }
    }

    private func save() async {
        saving = true
        saveMessage = nil
        defer { saving = false }
        do {
            let params: [String: AnyJSON] = [
                "help_contact_name":  name.isEmpty  ? .null : .string(name),
                "help_contact_phone": phone.isEmpty ? .null : .string(phone),
                "help_contact_email": email.isEmpty ? .null : .string(email),
            ]
            // resort_config has a single row — upsert on id=1 (or the first row).
            try await supabase
                .from("resort_config")
                .upsert(params, onConflict: "id")
                .execute()
            env.helpContactName  = name.isEmpty  ? HelpContact.name  : name
            env.helpContactPhone = phone.isEmpty ? HelpContact.phone : phone
            env.helpContactEmail = email.isEmpty ? HelpContact.email : email
            saveMessage = "Saved."
        } catch {
            saveMessage = "Couldn't save — check your connection."
            print("[AdminHelpContactView] save error: \(error)")
        }
    }
}
