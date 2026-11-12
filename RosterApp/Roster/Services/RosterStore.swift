import Foundation
import Observation

enum RosterStoreError: LocalizedError, Equatable {
    case corruptData(path: String)
    case readFailed(path: String, underlying: String)
    case unavailableDirectory(path: String)
    case missingSelectedFile(path: String)
    case changedOnDisk(path: String)
    case targetAppeared(path: String)
    case writeFailed(underlying: String)
    case blankName
    case duplicateEmail(String)
    case missingEmail
    case rosterNotFound

    var errorDescription: String? {
        switch self {
        case .corruptData(let path):
            return "Roster data at \(path) could not be read. Fix or remove the file; Roster has not overwritten it."
        case .readFailed(let path, let underlying):
            return "rosters.json in \(path) could not be read: \(underlying). Roster has not overwritten it."
        case .unavailableDirectory(let path):
            return "The roster folder at \(path) is not available. Restore or reconnect the folder; Roster will not treat it as an empty library."
        case .missingSelectedFile(let path):
            return "rosters.json is missing from \(path). Restore the file or choose another folder; Roster has not recreated it."
        case .changedOnDisk(let path):
            return "rosters.json in \(path) was changed by another instance or device. Your edit was not applied; the latest data is now shown, so try again."
        case .targetAppeared(let path):
            return "A rosters.json appeared in \(path) during the switch. Nothing was changed; review the folder and try again."
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
/// - A fresh default library (no file seen yet) treats a missing file as
///   zero rosters, not an error.
/// - A previously selected folder must exist and contain a readable, valid
///   rosters.json; an unavailable folder, unreadable file, corrupt JSON, or
///   a vanished once-seen file surfaces a blocking error and is never
///   overwritten or silently treated as an empty library.
/// - Mutations first compare the file against the last bytes this store
///   read or wrote and refuse to apply a stale edit when another writer
///   (a second instance or a synced device) saved meanwhile. This detects
///   local staleness only; sync providers may still create conflict copies
///   when offline clients edit simultaneously.
/// - Mutations revert in memory when their save fails, so the view model
///   never drifts from what is actually on disk.
@Observable
final class RosterStore {
    private(set) var rosters: [Roster] = []
    /// Non-nil means a load or save failure the UI must surface as blocking.
    private(set) var persistentError: RosterStoreError?
    /// The folder currently holding `rosters.json`; changes only via
    /// `switchDirectory(to:)`.
    private(set) var directory: URL
    private var fileURL: URL { directory.appendingPathComponent("rosters.json") }
    /// Exact bytes of the last file state this store read or wrote, used to
    /// detect out-of-band changes. Nil while no file has been seen here.
    private var lastSeenBytes: Data?
    /// True once a rosters.json has been read or written at the current
    /// location (or the folder was opened as a previously selected one).
    /// While false, a missing file is just an empty default library.
    private var fileExpected = false

    /// `directory` is injectable so tests can exercise persistence without
    /// touching the user's real Application Support. `requireExistingFile`
    /// marks a previously selected folder: its file must already exist and
    /// be valid, and a missing file is an error rather than an empty library.
    init(directory: URL? = nil, requireExistingFile: Bool = false) {
        self.directory = (directory ?? Self.defaultDirectory())
            .resolvingSymlinksInPath().standardizedFileURL
        if requireExistingFile {
            fileExpected = true
        }
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

    /// Re-reads the file. A changed file replaces the visible rosters;
    /// failures keep the last good rosters and set the blocking error. The
    /// on-disk file is never overwritten by a failed read.
    func reload() {
        do {
            try refresh()
        } catch let error as RosterStoreError {
            persistentError = error
        } catch {
            persistentError = .readFailed(
                path: fileURL.path, underlying: error.localizedDescription)
        }
    }

    /// Core read; throws instead of blocking. Assigns visible state only on
    /// success, and is a no-op when the bytes match what we last saw and no
    /// error is pending.
    private func refresh() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RosterStoreError.unavailableDirectory(path: directory.path)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if fileExpected {
                throw RosterStoreError.missingSelectedFile(path: fileURL.path)
            }
            rosters = []
            lastSeenBytes = nil
            persistentError = nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RosterStoreError.readFailed(path: fileURL.path, underlying: error.localizedDescription)
        }
        let decoded: [Roster]
        do {
            decoded = try JSONDecoder().decode([Roster].self, from: data)
        } catch {
            throw RosterStoreError.corruptData(path: fileURL.path)
        }
        if persistentError == nil, data == lastSeenBytes {
            return
        }
        rosters = decoded
        lastSeenBytes = data
        fileExpected = true
        persistentError = nil
    }

    /// Returns true when the on-disk file differs from the last bytes this
    /// store read or wrote. Throws blocking errors for an unavailable
    /// folder, unreadable file, or a vanished once-seen file.
    private func diskChangedExternally() throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RosterStoreError.unavailableDirectory(path: directory.path)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if fileExpected {
                throw RosterStoreError.missingSelectedFile(path: fileURL.path)
            }
            return lastSeenBytes != nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RosterStoreError.readFailed(path: fileURL.path, underlying: error.localizedDescription)
        }
        return data != lastSeenBytes
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

    /// Runs a mutation and saves. First adopts or rejects out-of-band disk
    /// changes; any thrown error aborts before the in-memory change; a save
    /// failure rolls the change back so memory matches disk.
    private func mutate<T>(_ validation: () throws -> T, then commit: (T) throws -> Void) throws {
        if let pendingError = persistentError {
            throw pendingError
        }
        do {
            try adoptOrRejectExternalChanges()
        } catch let error as RosterStoreError {
            // `.changedOnDisk` is transient: the newer data is already
            // loaded, so the UI shows it and a retry succeeds.
            if case .changedOnDisk = error {
                throw error
            }
            persistentError = error
            throw error
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

    /// Preflight shared by `mutate` and empty-target `switchDirectory`:
    /// reloads incoming changes and throws `.changedOnDisk` rather than
    /// letting a stale edit or stale snapshot win; records and throws the
    /// blocking error when the location is broken.
    private func adoptOrRejectExternalChanges() throws {
        guard try diskChangedExternally() else { return }
        try refresh()
        throw RosterStoreError.changedOnDisk(path: fileURL.path)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(rosters)
            try data.write(to: fileURL, options: [.atomic])
            lastSeenBytes = data
            fileExpected = true
        } catch {
            throw RosterStoreError.writeFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Folder switching

    /// Moves the store to `url` transactionally. A populated target is
    /// adopted (its rosters become the visible library; its bytes are never
    /// overwritten); an empty target receives the current rosters, published
    /// by renaming a uniquely named temporary file into place. The former
    /// file is never deleted or moved. Throws without changing any state
    /// when the target is unusable or the source is out of date.
    func switchDirectory(to url: URL) throws {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RosterStoreError.unavailableDirectory(path: target.path)
        }
        if target == directory {
            reload()
            return
        }
        let targetFileURL = target.appendingPathComponent("rosters.json")
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            // Adopt the target library; on any failure change nothing.
            let data: Data
            do {
                data = try Data(contentsOf: targetFileURL)
            } catch {
                throw RosterStoreError.readFailed(path: targetFileURL.path, underlying: error.localizedDescription)
            }
            let adopted: [Roster]
            do {
                adopted = try JSONDecoder().decode([Roster].self, from: data)
            } catch {
                throw RosterStoreError.corruptData(path: targetFileURL.path)
            }
            directory = target
            rosters = adopted
            lastSeenBytes = data
            fileExpected = true
            persistentError = nil
            return
        }
        // Empty target: publish the current library there. Refuse when the
        // source is unreadable or changed externally so a stale snapshot is
        // never copied. A blocked source may still be escaped via a
        // populated target above.
        if let pendingError = persistentError {
            throw pendingError
        }
        do {
            try adoptOrRejectExternalChanges()
        } catch let error as RosterStoreError {
            if case .changedOnDisk = error {
                throw error
            }
            persistentError = error
            throw error
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(rosters)
        } catch {
            throw RosterStoreError.writeFailed(underlying: error.localizedDescription)
        }
        let temporaryURL = target.appendingPathComponent("rosters-incoming-\(UUID().uuidString).json")
        do {
            try payload.write(to: temporaryURL, options: [.atomic])
            try FileManager.default.moveItem(at: temporaryURL, to: targetFileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            let nsError = error as NSError
            let targetAppearedNow =
                (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST))
            if targetAppearedNow {
                throw RosterStoreError.targetAppeared(path: targetFileURL.path)
            }
            throw RosterStoreError.writeFailed(underlying: error.localizedDescription)
        }
        directory = target
        lastSeenBytes = payload
        fileExpected = true
        persistentError = nil
    }
}
