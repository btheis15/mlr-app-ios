import SwiftUI

// MARK: - ScheduleSendPicker
//
// Shared "Send now" vs "Schedule for later" control for the broadcast composers
// (migration 0097). `selection` is nil for send-now, or a future Date once a
// send time is picked. The actual queuing/sending happens in the caller.

struct ScheduleSendPicker: View {
    /// nil = send now; a Date = schedule for that time.
    @Binding var selection: Date?

    private var minDate: Date { Date.now.addingTimeInterval(2 * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                segment(title: "Send now", isOn: selection == nil) {
                    selection = nil
                }
                segment(title: "Schedule for later", isOn: selection != nil) {
                    if selection == nil { selection = Date.now.addingTimeInterval(60 * 60) }
                }
            }

            if selection != nil {
                DatePicker(
                    "Send at",
                    selection: Binding(get: { selection ?? minDate }, set: { selection = $0 }),
                    in: minDate...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.mlrScaled(13))
            }
        }
        .padding(12)
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.mlrBorder, lineWidth: 1))
    }

    private func segment(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.mlrScaled(13, weight: .medium))
                .foregroundStyle(isOn ? Color.mlrPrimary : Color.mlrTextMuted)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isOn ? Color.mlrPrimary.opacity(0.12) : Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isOn ? Color.mlrPrimary.opacity(0.3) : Color.mlrBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
