import SwiftUI

// MARK: - AdminSystemView
//
// Media-server control (mirrors web /admin/system): shows the mini's current
// commit + how far behind origin/main it is, and a "Pull latest & restart"
// button — the mini pulls fast-forward-only then exits so launchd relaunches it
// on the new code (~10s). The server restricts the restart to the owner account
// (#381); everyone else gets a clear error.

struct AdminSystemView: View {
    @State private var status: ServerStatus?
    @State private var loading = true
    @State private var loadError: String?
    @State private var confirming = false
    @State private var restarting = false
    @State private var note: String?

    struct ServerStatus: Decodable {
        let ok: Bool
        let commit: String
        let upToDate: Bool
        let behind: Int
        let startedAt: String
    }
    struct RestartResult: Decodable {
        let ok: Bool
        let updated: Bool
        let from: String
        let to: String
        let filesChanged: Int
    }

    var body: some View {
        List {
            Section("Media server (Mac mini)") {
                if loading {
                    HStack(spacing: 10) { ProgressView(); Text("Checking the mini…").foregroundStyle(.secondary) }
                } else if let loadError {
                    Label(loadError, systemImage: "wifi.slash")
                        .foregroundStyle(Color.mlrDanger).font(.mlrScaled(13))
                } else if let status {
                    LabeledContent("Commit") { Text(String(status.commit.prefix(9))).monospaced() }
                    LabeledContent("Status") {
                        Text(status.upToDate ? "Up to date ✓" : "\(status.behind) commit\(status.behind == 1 ? "" : "s") behind")
                            .foregroundStyle(status.upToDate ? Color.mlrSuccess : Color.mlrWarning)
                    }
                    LabeledContent("Running since") { Text(formatted(status.startedAt)) }
                }
            }

            Section {
                Button(restarting ? "Restarting…" : "Pull latest & restart") { confirming = true }
                    .disabled(restarting || loading)
                    .foregroundStyle(Color.mlrDanger)
            } footer: {
                Text("Pulls origin/main (fast-forward only) into the mini's checkout, then restarts — push, email, and uploads pause for well under a minute. Owner-only; the server rejects anyone else.")
            }

            if let note {
                Section { Text(note).font(.mlrScaled(13)).foregroundStyle(Color.mlrPrimary) }
            }
        }
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Restart the media server?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Pull & restart", role: .destructive) { Task { await restart() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Push, email, and uploads pause briefly while it relaunches.")
        }
    }

    // MARK: Data

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            status = try await request("GET", "/admin/media-server-status")
        } catch {
            loadError = "Couldn't reach the mini — are you on Tailscale?"
        }
    }

    private func restart() async {
        restarting = true; note = nil
        defer { restarting = false }
        do {
            let r: RestartResult = try await request("POST", "/admin/restart-media-server")
            note = r.updated
                ? "Updated \(String(r.from.prefix(7))) → \(String(r.to.prefix(7))) (\(r.filesChanged) files) — relaunching…"
                : "Already up to date — relaunching…"
            // Give launchd a moment, then refresh the status card.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await load()
        } catch {
            note = "Restart refused — owner-only, or the mini is unreachable."
        }
    }

    private func request<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        let session = try await supabase.auth.session
        guard let url = URL(string: MediaService.miniServerURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formatted(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
