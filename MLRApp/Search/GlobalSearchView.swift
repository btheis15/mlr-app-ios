import SwiftUI

// MARK: - Global search screen
//
// The destination the `.system.searchInApp` Siri / Apple Intelligence intent
// navigates to (and the Home search button opens). Runs `ResortSearch` across
// all resort content and renders grouped, tappable results. Tapping a result
// dismisses the sheet and hands its `mlr://` URL to `IntentRouter`, reusing the
// app's existing deep-link routing.

/// Identifiable wrapper so `RootView` can present the screen via `.sheet(item:)`
/// and carry the Siri-provided search term.
struct GlobalSearchRequest: Identifiable {
    let id = UUID()
    let term: String
}

struct GlobalSearchView: View {
    let initialTerm: String

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var groups: [ResortSearchGroup] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if isSearching && groups.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching Up North…")
                        .font(.mlrScaled(15))
                        .foregroundStyle(.secondary)
                }
            } else if groups.isEmpty && !trimmedQuery.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "Search Up North",
                    systemImage: "magnifyingglass",
                    description: Text("Find people, committees, events, the work list, Family Fest, and chats.")
                )
            } else {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.hits) { hit in
                            Button { open(hit) } label: { row(hit) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Up North"
        )
        .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        .task {
            query = initialTerm
            if !trimmedQuery.isEmpty { await runSearch(trimmedQuery) }
        }
    }

    private func row(_ hit: ResortSearchHit) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hit.symbol)
                .font(.mlrScaled(16))
                .foregroundStyle(Color.mlrPrimary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(.mlrScaled(15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle)
                        .font(.mlrScaled(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Search

    /// Debounce keystrokes so we don't fire a query on every character.
    private func scheduleSearch(_ term: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await runSearch(term.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @MainActor
    private func runSearch(_ term: String) async {
        guard !term.isEmpty else {
            groups = []
            isSearching = false
            return
        }
        isSearching = true
        let result = await ResortSearch.run(term: term)
        // Drop stale results if the query moved on while we were fetching.
        guard term == trimmedQuery else { return }
        groups = result
        isSearching = false
    }

    // MARK: Navigation

    private func open(_ hit: ResortSearchHit) {
        let route = IntentRouter.Route(url: hit.url)
        dismiss()
        guard let route else { return }
        // Let the sheet finish dismissing before routing (which may itself
        // switch tabs or present another sheet).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            IntentRouter.shared.requestRoute(route)
        }
    }
}
