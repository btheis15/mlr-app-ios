import Foundation

// MARK: - Watch chat send
//
// Minimal message insert for the watch (dictation reply). RLS requires
// author_id == auth.uid(); we set it from the session the phone handed over.
// Committee sends go to the General channel (area = null).

extension WatchData {
    @discardableResult
    public static func sendMessage(_ text: String, to convo: WatchConversation) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let uid = supabase.auth.currentUser?.id.uuidString else { return false }
        do {
            switch convo.kind {
            case .committee(let id):
                struct Row: Encodable { let committee_id: String; let author_id: String; let text: String }
                try await supabase.from("committee_messages")
                    .insert(Row(committee_id: id.uuidString, author_id: uid, text: trimmed))
                    .execute()
            case .house(let id):
                struct Row: Encodable { let house_id: String; let author_id: String; let text: String }
                try await supabase.from("house_messages")
                    .insert(Row(house_id: id.uuidString, author_id: uid, text: trimmed))
                    .execute()
            }
            return true
        } catch {
            print("[WatchData] sendMessage failed: \(error)")
            return false
        }
    }
}
