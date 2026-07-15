import SwiftUI
import Supabase

// MARK: - AdminInviteView
// Admins paste email addresses — one per line, or comma/semicolon-separated —
// and the media server sends each a branded invite email with a sign-in button
// (no OTP code to type). Mirrors web AdminInviteEmails.tsx.

private struct ParsedEntry: Identifiable {
    let id = UUID()
    let email: String
    let name: String?
    let valid: Bool
}

private func parseEntries(_ raw: String) -> [ParsedEntry] {
    let emailPattern = try? NSRegularExpression(pattern: #"^\S+@\S+\.\S+$"#)
    let pieces = raw
        .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    var seen = Set<String>()
    var out: [ParsedEntry] = []
    for piece in pieces {
        let email: String
        let name: String?
        // "Name <email@x.com>" format
        if let range = piece.range(of: #"<([^>]+)>$"#, options: .regularExpression) {
            let inner = String(piece[range]).dropFirst().dropLast()
            email = String(inner).trimmingCharacters(in: .whitespaces)
            let before = piece[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            name = before.isEmpty ? nil : before
        } else {
            email = piece
            name = nil
        }
        let key = email.lowercased()
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        let range = NSRange(email.startIndex..., in: email)
        let valid = emailPattern?.firstMatch(in: email, range: range) != nil
        out.append(ParsedEntry(email: email, name: name, valid: valid))
    }
    return out
}

private struct InviteResult: Identifiable {
    let id = UUID()
    let email: String
    let ok: Bool
    let error: String?
}

struct AdminInviteView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var raw = ""
    @State private var results: [InviteResult] = []
    @State private var sending = false
    @State private var statusMessage: String? = nil

    private var parsed: [ParsedEntry] { parseEntries(raw) }
    private var validEntries: [ParsedEntry] { parsed.filter(\.valid) }
    private var invalidCount: Int { parsed.filter { !$0.valid }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    if !parsed.isEmpty { parsePreview }
                    sendButton
                    if let msg = statusMessage {
                        Text(msg)
                            .font(.mlrScaled(13))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                    if !results.isEmpty { resultsCard }
                }
                .padding(16)
                .padding(.bottom, 32)
            }
            .background(Color.mlrSurface)
            .navigationTitle("Invite People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sub-views

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite by email")
                .font(.mlrScaled(14, weight: .semibold))
                .foregroundStyle(Color.mlrText)
            Text("One per line, or comma/semicolon-separated. Use \"Name <email>\" to personalize. Each person gets a private email with a sign-in button — no code to type.")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $raw)
                    .font(.mlrScaled(13))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                if raw.isEmpty {
                    Text("jane@example.com\nJohn Smith <john@example.com>")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .cardStyle()
    }

    private var parsePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(validEntries.count) ready to send\(invalidCount > 0 ? "  ·  \(invalidCount) need fixing" : "")")
                .font(.mlrScaled(12, weight: .medium))
                .foregroundStyle(Color.mlrTextMuted)
            ForEach(parsed) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(entry.valid ? Color.mlrPrimary : Color.mlrAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        if let name = entry.name {
                            Text(name)
                                .font(.mlrScaled(13, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                        }
                        Text(entry.email)
                            .font(.mlrScaled(12))
                            .foregroundStyle(entry.name != nil ? Color.mlrTextMuted : Color.mlrText)
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    private var sendButton: some View {
        Button {
            Task { await sendInvites() }
        } label: {
            HStack(spacing: 8) {
                if sending { ProgressView().tint(.white) }
                let count = validEntries.count
                Text(sending ? "Sending\u{2026}" : count > 0
                     ? "Send \(count) invite\(count == 1 ? "" : "s")"
                     : "Send invites")
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.mlrPrimary.opacity(sending || validEntries.isEmpty ? 0.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(sending || validEntries.isEmpty)
        .buttonStyle(.plain)
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(Color.mlrText)
            ForEach(results) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.ok ? Color.mlrPrimary : Color.mlrDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.email)
                            .font(.mlrScaled(13, weight: .medium))
                            .foregroundStyle(Color.mlrText)
                        if let err = r.error {
                            Text(err)
                                .font(.mlrScaled(11))
                                .foregroundStyle(Color.mlrDanger)
                        }
                    }
                }
            }
        }
        .padding(14)
        .cardStyle()
    }

    // MARK: - Actions

    private func sendInvites() async {
        guard !validEntries.isEmpty else { return }
        guard let token = try? await supabase.auth.session.accessToken else {
            statusMessage = "Sign in again to send invites."
            return
        }
        sending = true
        statusMessage = nil
        results = []
        defer { sending = false }

        guard let url = URL(string: "\(MediaService.miniServerURL)/admin/invite-link") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let entries = validEntries.map { e -> [String: String] in
            var d = ["email": e.email]
            if let n = e.name { d["name"] = n }
            return d
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entries": entries])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                statusMessage = "Server returned an error \u{2014} check the media server connection."
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawResults = json["results"] as? [[String: Any]] {
                results = rawResults.map { r in
                    InviteResult(
                        email: r["email"] as? String ?? "",
                        ok: r["ok"] as? Bool ?? false,
                        error: r["error"] as? String
                    )
                }
                let okCount = results.filter(\.ok).count
                statusMessage = "Sent \(okCount) of \(results.count) invite\(results.count == 1 ? "" : "s")."
            }
        } catch {
            statusMessage = "Couldn\u{2019}t reach the media server \u{2014} check your connection."
        }
    }
}
