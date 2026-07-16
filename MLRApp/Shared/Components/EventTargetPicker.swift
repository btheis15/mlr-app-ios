import SwiftUI

// MARK: - EventTargetPicker
//
// Shared "link this broadcast to an event" control (migration 0096): pick an
// upcoming event to scope the send, and optionally skip anyone who RSVP'd "Can't
// make it" to it. Used by AdminNotificationComposer and AdminAlertComposer.

struct EventTargetPicker: View {
    let events: [ResortEvent]
    @Binding var selectedEventId: String?
    @Binding var excludeNotAttending: Bool

    var body: some View {
        Section {
            Picker("Link to event", selection: $selectedEventId) {
                Text("No specific event").tag(String?.none)
                ForEach(events) { event in
                    Text(event.title).tag(String?.some(event.id))
                }
            }
            .onChange(of: selectedEventId) { _, newValue in
                if newValue != nil { excludeNotAttending = true }
            }

            if selectedEventId != nil {
                Toggle(isOn: $excludeNotAttending) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip people who declined")
                            Text("Don't send to anyone who RSVP'd \"Can't make it\"")
                                .font(.caption)
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    } icon: {
                        Image(systemName: "person.slash.fill")
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                }
                .tint(Color.mlrPrimary)
            }
        } header: {
            Text("Event filter")
        } footer: {
            if selectedEventId == nil {
                Text("Optionally link this to an event — lets you skip people who RSVP'd they can't attend.")
                    .font(.caption)
            }
        }
    }
}
