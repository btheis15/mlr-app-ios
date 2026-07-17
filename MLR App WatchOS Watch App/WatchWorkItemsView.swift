import SwiftUI
import MLRCore

// MARK: - Work Items (watch)
// Read-only list of open resort work-checklist items, most urgent first.

struct WatchWorkItemsView: View {
    @Environment(WatchSessionReceiver.self) private var session

    @State private var items: [WatchWorkItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !session.isAuthed {
                notSyncedHint
            } else if items.isEmpty {
                Text(loaded ? "Nothing open — all caught up! ✅" : "Loading…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.urgencyEmoji).font(.system(size: 12))
                        Text(item.title)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Work")
        .task(id: session.isAuthed) {
            guard session.isAuthed else { return }
            items = await WatchData.openWorkItems()
            loaded = true
        }
    }

    private var notSyncedHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Open the MLR app on your iPhone to sync.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
