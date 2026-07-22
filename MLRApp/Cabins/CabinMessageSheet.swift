import SwiftUI

// MARK: - CabinMessageSheet (send_cabin_message, migration 0120)
//
// The approver (or an admin) messages everyone with an approved, not-yet-ended
// stay at a place. Fans a 'cabin_message' notification to each recipient, and —
// with the email box ticked — the mac-mini BCCs those with email alerts on.
// Gated server-side by is_cabin_approver.

struct CabinMessageSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let cabinId: UUID
    let cabinName: String

    @State private var subject = ""
    @State private var body_ = ""
    @State private var alsoEmail = false
    @State private var sending = false
    @State private var errorText: String?
    @State private var sentCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                if let sentCount {
                    Section {
                        Label(sentCount == 0
                              ? "No one has an active stay here right now."
                              : "Sent to \(sentCount) guest\(sentCount == 1 ? "" : "s").",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.mlrSuccess)
                    }
                } else {
                    Section {
                        TextField("Subject (optional)", text: $subject)
                        TextField("Message", text: $body_, axis: .vertical).lineLimit(4...10)
                    } header: {
                        Text("Message everyone staying at \(cabinName)")
                    } footer: {
                        Text("Goes to everyone with an approved stay that hasn't ended yet.")
                    }
                    Section {
                        Toggle("Also email them", isOn: $alsoEmail).tint(Color.mlrPrimary)
                    } footer: {
                        Text("Emails guests who have email alerts on, in addition to the in-app notification.")
                    }
                    if let errorText {
                        Section { Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger) }
                    }
                }
            }
            .navigationTitle("Message guests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sentCount == nil ? "Cancel" : "Done") { dismiss() }
                }
                if sentCount == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(sending ? "Sending…" : "Send") { Task { await send() } }
                            .disabled(sending || body_.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true; errorText = nil
        defer { sending = false }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let count = try await env.cabinService.sendCabinMessage(
                cabinId: cabinId,
                subject: trimmedSubject.isEmpty ? nil : trimmedSubject,
                body: body_.trimmingCharacters(in: .whitespacesAndNewlines),
                email: alsoEmail)
            Haptics.success()
            sentCount = count
        } catch {
            errorText = "Couldn't send the message."
        }
    }
}
