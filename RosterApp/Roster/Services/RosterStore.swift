import Foundation
import Observation

enum RosterStoreError: LocalizedError, Equatable {
    case corruptData(path: String)
    case writeFailed(underlying: String)
    case blankName
    case duplicateEmail(String)
    case missingEmail
    case rosterNotFound

    var errorDescription: String? {
        switch self {
        case .corruptData(let path):
            return "Roster data at \(path) could not be read. Fix or remove the file; Roster has not overwritten it."
        case .writeFailed(let underlying):
            return "Saving rosters failed: \(underlying)"
        case .blankName:
            return "A roster name cannot be empty."
        case .duplicateEmail(let email):
            return "\(email) is already in this roster."
        case .missingEmail:
            return "A roster member needs an email address."
        case .rosterNotFound:
            return "That roster no longer exists."
        }
    }
}

/// Owns the saved rosters. File-on-disk rules:
/// - Missing file means zero rosters, not an error.
/// - Undecodable file surfaces a blocking error and is never overwritten by us.
/// - Mutations revert in memory when their save fails, so the view model never
///   drifts from what is actually on disk.
@Observable
final class RosterStore {
    private(set) var rosters: [Roster] = []
    /// Non-nil means a load or save failure the UI must surface as blocking.
    private(set) var persistentError: RosterStoreError?

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("rosters.json") }

    /// `directory` is injectable so tests can exercise persistence without
    /// touching the user's real Application Support.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        reload()
    }

    static func defaultDirectory() -> URL {
        // Should only fail with a malformed sandbox/home configuration; a
        // crash here is better than silently dropping rosters.
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = support.appendingPathComponent("Roster", isDirectory: true)
        try! FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    /// Re-reads the file. Corrupt data keeps the empty in-memory list and sets
    /// the blocking error; the on-disk file is left untouched.
    func reload() {
        guard (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil else {
            rosters = []
            persistentError = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            rosters = try JSONDecoder().decode([Roster].self, from: data)
            persistentError = nil
        } catch {
            rosters = []
            persistentError = .corruptData(path: fileURL.path)
        }
    }

    // MARK: - Mutations (each mutation saves; failures roll back the change)

    func createRoster(named rawName: String) throws -> Roster {
        var created: Roster?
        try mutate({ try validatedName(rawName) }, then: { name in
            let roster = Roster(id: UUID(), name: name, members: [])
            rosters.append(roster)
            created = roster
        })
        return created!
    }

    func renameRoster(_ id: UUID, to rawName: String) throws {
        try mutate({ try validatedName(rawName) }, then: { name in
            guard let index = rosters.firstIndex(where: { $0.id == id }) else { throw RosterStoreError.rosterNotFound }
            rosters[index].name = name
        })
    }

    func deleteRoster(_ id: UUID) throws {
        try mutate({ () in }, then: { _ in
            guard rosters.contains(where: { $0.id == id }) else { throw RosterStoreError.rosterNotFound }
            rosters.removeAll { $0.id == id }
        })
    }

    /// Adds a member. Emails are trimmed, lowercased-compared for dedupe, and
    /// required; empty names fall back to the address itself.
    func addMember(to rosterID: UUID, displayName: String, email rawEmail: String, contactIdentifier: String? = nil) throws {
        try mutate({ () -> String in
            let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { throw RosterStoreError.missingEmail }
            return email
        }, then: { email in
            guard let index = rosters.firstIndex(where: { $0.id == rosterID }) else { throw RosterStoreError.rosterNotFound }
            let normalized = email.lowercased()
            guard !rosters[index].members.contains(where: { $0.email.lowercased() == normalized }) else {
                throw RosterStoreError.duplicateEmail(email)
            }
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            rosters[index].members.append(
                Invitee(id: UUID(), contactIdentifier: contactIdentifier, displayName: name.isEmpty ? email : name, email: email)
            )
        })
    }

    /// Adds several parsed entries in one persisted mutation. Case-insensitive
    /// duplicates — within the pasted list or against existing members — are
    /// skipped and reported. `contactIdentifier` is nil for pasted entries.
    func addParsedMembers(to rosterID: UUID, entries: [EmailListParser.Entry]) throws -> (added: Int, duplicates: [String]) {
        var added = 0
        var duplicates: [String] = []
        try mutate({ () in }, then: { _ in
            guard let index = rosters.firstIndex(where: { $0.id == rosterID }) else { throw RosterStoreError.rosterNotFound }
            var seen = Set(rosters[index].members.map { $0.email.lowercased() })
            for entry in entries {
                let normalized = entry.email.lowercased()
                if seen.contains(normalized) {
                    duplicates.append(entry.email)
                    continue
                }
                seen.insert(normalized)
                let name = entry.name.isEmpty ? entry.email : entry.name
                rosters[index].members.append(
                    Invitee(id: UUID(), contactIdentifier: nil, displayName: name, email: entry.email)
                )
                added += 1
            }
        })
        return (added, duplicates)
    }

    func removeMember(from rosterID: UUID, memberID: UUID) throws {
        try mutate({ () in }, then: { _ in
            guard let index = rosters.firstIndex(where: { $0.id == rosterID }) else { throw RosterStoreError.rosterNotFound }
            guard rosters[index].members.contains(where: { $0.id == memberID }) else { throw RosterStoreError.rosterNotFound }
            rosters[index].members.removeAll { $0.id == memberID }
        })
    }

    /// Updates the card's emoji icon and/or background color. Either value
    /// may be nil or empty to clear it. Color hex is normalized to
    /// "#RRGGBB"; unparseable values clear the color.
    func setAppearance(rosterID: UUID, emoji rawEmoji: String?, backgroundColorHex rawHex: String?) throws {
        try mutate({ () in }, then: { _ in
            guard let index = rosters.firstIndex(where: { $0.id == rosterID }) else { throw RosterStoreError.rosterNotFound }
            if let emoji = rawEmoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
                rosters[index].emoji = String(emoji.prefix(8))
            } else {
                rosters[index].emoji = nil
            }
            rosters[index].backgroundColorHex = Self.normalizedHex(rawHex)
        })
    }

    private static func normalizedHex(_ raw: String?) -> String? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }

    /// Reorders rosters, preserving the new order on disk. Mirrors
    /// `Array.move(fromOffsets:toOffset:)` semantics for SwiftUI `.onMove`.
    func moveRosters(fromOffsets offsets: IndexSet, toOffset: Int) throws {
        try mutate({ () in }, then: { _ in
            // Mirrors Array.move(fromOffsets:toOffset:) without importing
            // SwiftUI into the persistence layer: remove the offsets back to
            // front, then insert them at the adjusted destination.
            var items = rosters
            var insertAt = max(0, min(items.count, toOffset))
            var moving: [Roster] = []
            for index in offsets.sorted(by: >) {
                if index < insertAt { insertAt -= 1 }
                moving.insert(items.remove(at: index), at: 0)
            }
            items.insert(contentsOf: moving, at: insertAt)
            rosters = items
        })
    }

    // MARK: - Internals

    private func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RosterStoreError.blankName }
        return name
    }

    /// Runs a mutation and saves. Any thrown error aborts before the in-memory
    /// change; a save failure rolls the change back so memory matches disk.
    private func mutate<T>(_ validation: () throws -> T, then commit: (T) throws -> Void) throws {
        if let pendingError = persistentError {
            throw pendingError
        }
        let applied = try validation()
        let snapshot = rosters
        try commit(applied)
        do {
            try save()
        } catch {
            rosters = snapshot
            throw error
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(rosters)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw RosterStoreError.writeFailed(underlying: error.localizedDescription)
        }
    }
}
