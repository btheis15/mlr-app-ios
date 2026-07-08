import AppIntents
import Foundation

// MARK: - Member query intents (Siri / Apple Intelligence)
//
// Answer questions about family members from the directory — starting with
// birthdays ("When is Jessica's birthday?"). The member is resolved by name via
// MemberEntityQuery (EntityStringQuery), so Siri can match a spoken first name.

struct BirthdayIntent: AppIntent {
    static var title: LocalizedStringResource = "Look Up a Birthday"
    static var description = IntentDescription("Find out when a family member's birthday is.")

    @Parameter(title: "Member", requestValueDialog: "Whose birthday?")
    var member: MemberEntity

    static var parameterSummary: some ParameterSummary {
        Summary("When is \(\.$member)'s birthday")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let raw = member.birthday?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .result(dialog: "I don't have a birthday on file for \(member.name).")
        }
        let pretty = Self.friendly(raw) ?? raw
        return .result(dialog: IntentDialog(stringLiteral: "\(member.name)'s birthday is \(pretty)."))
    }

    /// Turn a stored birthday string into "June 14", tolerating a few formats.
    /// Falls back to nil (caller speaks the raw value) if nothing parses.
    static func friendly(_ raw: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMMM d"
        for fmt in ["yyyy-MM-dd", "MM-dd", "M/d", "MM/dd", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            parser.dateFormat = fmt
            if let d = parser.date(from: raw) { return out.string(from: d) }
        }
        return nil
    }
}
