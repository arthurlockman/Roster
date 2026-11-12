import Foundation

/// One saved address inside a roster. `email` is a snapshot captured at the
/// moment the member was added, so later edits in Contacts never silently
/// change who an invitation targets. `contactIdentifier` is source attribution
/// only and may be stale or nil for manually typed addresses.
nonisolated struct Invitee: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var contactIdentifier: String?
    var displayName: String
    var email: String
}

/// A named, editable invitee set owned by the app. Persisted as JSON in
/// Application Support; Contacts groups are never touched.
nonisolated struct Roster: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var members: [Invitee]
    /// Optional single-glyph icon shown on the roster card.
    var emoji: String?
    /// Optional opaque card background as "#RRGGBB" hex; nil uses the
    /// system secondary background.
    var backgroundColorHex: String?
}

/// Parses a pasted list of email addresses: entries may be separated by
/// commas or newlines (mixed freely), and each entry is either a bare
/// address or the RFC display form `Firstname Lastname <email@host>`.
/// Names containing commas ("Doe, John <…>") are out of spec and degrade
/// to two tokens; the address usually survives in one of them.
nonisolated enum EmailListParser {
    nonisolated struct Entry: Equatable, Sendable {
        var name: String
        var email: String
    }

    nonisolated struct Result: Equatable, Sendable {
        var entries: [Entry]
        var invalid: [String]
    }

    static func parse(_ raw: String) -> Result {
        var entries: [Entry] = []
        var invalid: [String] = []
        for token in raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" }) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let entry = entry(from: trimmed) {
                entries.append(entry)
            } else {
                invalid.append(trimmed)
            }
        }
        return Result(entries: entries, invalid: invalid)
    }

    private static func entry(from token: String) -> Entry? {
        if token.hasSuffix(">"), let open = token.lastIndex(of: "<") {
            let name = token[..<open].trimmingCharacters(in: .whitespaces)
            let email = token[token.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
            guard isValidEmail(email) else { return nil }
            return Entry(name: name, email: normalized(email))
        }
        guard isValidEmail(token) else { return nil }
        return Entry(name: "", email: normalized(token))
    }

    /// Same loose shape rule as manual entry: exactly one `@` with non-empty
    /// parts. Deliverability is Calendar.app's problem, as everywhere else.
    static func isValidEmail(_ raw: String) -> Bool {
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Comparison is case-insensitive downstream; the stored address keeps
    /// its original case but loses a `mailto:` prefix if pasted with one.
    private static func normalized(_ raw: String) -> String {
        raw.hasPrefix("mailto:") ? String(raw.dropFirst("mailto:".count)) : raw
    }
}
