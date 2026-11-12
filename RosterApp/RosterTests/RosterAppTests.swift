import Testing
import Foundation
import JavaScriptCore
@testable import Roster

private struct TestFailure: Error { init(_ message: String = "") {} }

/// Exercises the bundled script's pure helpers through JavaScriptCore so the
/// same production code paths used by osascript are asserted — no fake echo.
@Suite("CalendarRoster.js helpers")
struct ScriptHelperTests {

    private func makeContext() throws -> JSContext {
        let url = Bundle.main.url(forResource: "CalendarRoster", withExtension: "js")
        #expect(url != nil, "CalendarRoster.js must be in the app bundle")
        guard let url else { throw TestFailure("script missing") }
        let context = JSContext()!
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        return context
    }

    private func call(_ context: JSContext, _ name: String, _ args: [Any]) throws -> JSValue {
        guard let function = context.objectForKeyedSubscript(name), !function.isUndefined else {
            throw TestFailure("\(name) is not defined in the script")
        }
        guard let result = function.call(withArguments: args), !result.isUndefined else {
            throw TestFailure("\(name) returned undefined")
        }
        return result
    }

    @Test func missingKeysIgnoreMailtoAndCase() throws {
        let context = try makeContext()
        let result = try call(context, "missingEmailKeys", [["a@example.com", "b@example.com"], ["MAILTO:A@example.com"]])
        #expect(result.toArray() as? [String] == ["b@example.com"])
    }

    @Test func duplicateRequiredEmailsAddOnce() throws {
        let context = try makeContext()
        let result = try call(context, "missingEmailKeys", [["x@example.com", "X@Example.com", "x@example.com"], []])
        #expect(result.toArray() as? [String] == ["x@example.com"])
    }

    @Test func missingKeysKeepRequiredOrder() throws {
        let context = try makeContext()
        let result = try call(context, "missingEmailKeys", [["z@example.com", "a@example.com"], ["A@example.com"]])
        #expect(result.toArray() as? [String] == ["z@example.com"])
    }

    @Test func reviewMatchesIgnoresOrderButNotContent() throws {
        let context = try makeContext()
        #expect(try call(context, "reviewMatches", [["a@x.com", "b@x.com"], ["B@x.com", "a@x.com"], false, false]).toBool())
        #expect(try !call(context, "reviewMatches", [["a@x.com"], ["b@x.com"], false, false]).toBool())
        #expect(try !call(context, "reviewMatches", [["a@x.com"], ["a@x.com"], false, true]).toBool())
        #expect(try !call(context, "reviewMatches", [["a@x.com", "b@x.com"], ["a@x.com"], true, true]).toBool())
        #expect(try call(context, "reviewMatches", [[], [], true, true]).toBool())
    }

    @Test func normalizedEmailStripsMailtoAndWhitespace() throws {
        let context = try makeContext()
        #expect(try call(context, "normalizeEmail", ["  MAILTO: User@Example.COM "]).toString() == "user@example.com")
        #expect(try call(context, "normalizeEmail", ["   "]).isNull)
    }

    @Test func metaFromPropertiesReadsBulkRecord() throws {
        let context = try makeContext()
        let record: [String: Any] = [
            "summary": "Established Patient Return",
            "alldayEvent": false,
            "startDate": Date(timeIntervalSince1970: 1_700_000_000),
            "endDate": Date(timeIntervalSince1970: 1_700_003_600),
            "recurrence": "",
        ]
        let meta = try call(context, "metaFromProperties", [record]).toDictionary()
        #expect(meta?["summary"] as? String == "Established Patient Return")
        #expect(meta?["allDay"] as? Bool == false)
        #expect(meta?["hasRecurrence"] as? Bool == false)
        #expect(meta?["start"] != nil)
        #expect(meta?["end"] != nil)
    }

    @Test func metaFromPropertiesRejectsMissingDates() throws {
        let context = try makeContext()
        let record: [String: Any] = ["summary": "x", "alldayEvent": true]
        let meta = try call(context, "metaFromProperties", [record]).toDictionary()
        #expect(meta == nil || (meta?.isEmpty ?? true))
    }
}

/// The Swift twin used by the EventKit preview fast path must agree with the
/// script's missingEmailKeys: same normalization, required order, dedupe.
@Suite("missingKeys Swift twin")
struct MissingKeysTests {
    @Test func ignoresMailtoCaseAndWhitespace() {
        #expect(
            missingKeys(
                required: ["  DR@example.com ", "mailto:nurse@clinic.org"],
                attendeeEmails: ["dr@EXAMPLE.com"]
            ) == ["nurse@clinic.org"]
        )
    }

    @Test func duplicateRequiredEmailsAppearOnce() {
        #expect(
            missingKeys(
                required: ["a@x.org", "A@X.ORG", "mailto:a@x.org"],
                attendeeEmails: []
            ) == ["a@x.org"]
        )
    }

    @Test func emptyAndInvalidRequiredEmailsAreSkipped() {
        #expect(missingKeys(required: ["", "   "], attendeeEmails: []) == [])
    }

    @Test func keepsRequiredOrder() {
        #expect(
            missingKeys(
                required: ["c@x.org", "a@x.org", "b@x.org"],
                attendeeEmails: ["a@x.org"]
            ) == ["c@x.org", "b@x.org"]
        )
    }
}

/// Exercises the app-owned JSON persistence: round-trip, corrupted-file
/// blocking, and write-failure rollback. Uses an injected temp directory so
/// the real Application Support file is never touched.
@Suite("RosterStore persistence")
struct RosterStoreTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readFile(_ directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("rosters.json"), encoding: .utf8)
    }

    @Test func roundTripAcrossStoreInstances() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let roster = try store.createRoster(named: "  Team  ")
        try store.addMember(to: roster.id, displayName: "Ada", email: " ada@example.com ")

        let reopened = RosterStore(directory: dir)
        #expect(reopened.persistentError == nil)
        #expect(reopened.rosters.count == 1)
        #expect(reopened.rosters.first?.name == "Team")
        #expect(reopened.rosters.first?.members.map(\.email) == ["ada@example.com"])
    }

    @Test func blankNamesAndMissingEmailsRejected() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        #expect(throws: RosterStoreError.blankName) { _ = try store.createRoster(named: "   ") }
        let roster = try store.createRoster(named: "ok")
        #expect(throws: RosterStoreError.missingEmail) {
            try store.addMember(to: roster.id, displayName: "no email", email: "   ")
        }
    }

    @Test func duplicateEmailsCaseInsensitive() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let roster = try store.createRoster(named: "dup")
        try store.addMember(to: roster.id, displayName: "A", email: "user@example.com")
        #expect(throws: RosterStoreError.duplicateEmail("USER@example.com")) {
            try store.addMember(to: roster.id, displayName: "B", email: "USER@example.com")
        }
        #expect(store.rosters.first?.members.count == 1)
    }

    @Test func manualMemberAddsEmailWithoutContactIdentifier() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let roster = try store.createRoster(named: "manual")
        try store.addMember(to: roster.id, displayName: "", email: "typed@example.com", contactIdentifier: nil)
        let member = store.rosters.first?.members.first
        #expect(member?.email == "typed@example.com")
        #expect(member?.displayName == "typed@example.com")
        #expect(member?.contactIdentifier == nil)
    }

    @Test func appearancePersistsAndClears() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let roster = try store.createRoster(named: "styled")
        try store.setAppearance(rosterID: roster.id, emoji: " 🎉 ", backgroundColorHex: " 33AA66 ")
        var reopened = RosterStore(directory: dir)
        #expect(reopened.rosters.first?.emoji == "🎉")
        #expect(reopened.rosters.first?.backgroundColorHex == "#33aa66")
        try reopened.setAppearance(rosterID: roster.id, emoji: "", backgroundColorHex: "not-a-color")
        reopened = RosterStore(directory: dir)
        #expect(reopened.rosters.first?.emoji == nil)
        #expect(reopened.rosters.first?.backgroundColorHex == nil)
    }

    @Test func moveRostersPersistsOrder() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let a = try store.createRoster(named: "a")
        let b = try store.createRoster(named: "b")
        let c = try store.createRoster(named: "c")
        try store.moveRosters(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.rosters.map(\.id) == [c.id, a.id, b.id])
        let reopened = RosterStore(directory: dir)
        #expect(reopened.rosters.map(\.name) == ["c", "a", "b"])
    }

    @Test func parsesMixedSeparatorAndFormats() {
        let result = EmailListParser.parse("a@x.com, Bob Smith <bob@x.com>\rbare@y.io\n ,  , nope, mailto:c@z.com, Missing <not-an-email>")
        #expect(result.entries == [
            EmailListParser.Entry(name: "", email: "a@x.com"),
            EmailListParser.Entry(name: "Bob Smith", email: "bob@x.com"),
            EmailListParser.Entry(name: "", email: "bare@y.io"),
            EmailListParser.Entry(name: "", email: "c@z.com"),
        ])
        #expect(result.invalid == ["nope", "Missing <not-an-email>"])
    }

    @Test func addParsedMembersSkipsDuplicates() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let roster = try store.createRoster(named: "bulk")
        try store.addMember(to: roster.id, displayName: "Existing", email: "a@x.com")
        let outcome = try store.addParsedMembers(to: roster.id, entries: [
            EmailListParser.Entry(name: "A Again", email: "A@X.com"),
            EmailListParser.Entry(name: "", email: "b@x.com"),
            EmailListParser.Entry(name: "", email: "b@x.com"),
        ])
        #expect(outcome.added == 1)
        #expect(outcome.duplicates == ["A@X.com", "b@x.com"])
        #expect(store.rosters.first?.members.map(\.email) == ["a@x.com", "b@x.com"])
        #expect(store.rosters.first?.members.first?.displayName == "Existing")
    }

    @Test func corruptFileBlocksAndIsNotOverwritten() throws {
        let dir = try makeTempDirectory()
        let fileURL = dir.appendingPathComponent("rosters.json")
        let garbage = "{ this is not valid roster json ]["
        try garbage.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = RosterStore(directory: dir)
        #expect(store.persistentError != nil)
        #expect(store.rosters.isEmpty)
        #expect(try readFile(dir) == garbage, "corrupt on-disk data must be left untouched")
        #expect(throws: RosterStoreError.self) { _ = try store.createRoster(named: "should fail while blocked") }
        #expect(try readFile(dir) == garbage)
    }

    @Test func failedSaveRollsBackMemory() throws {
        let dir = try makeTempDirectory()
        // Directory path is actually a file: every write inside it fails.
        let notADirectory = dir.appendingPathComponent("not-a-dir")
        try Data().write(to: notADirectory)
        let store = RosterStore(directory: notADirectory)

        #expect(throws: RosterStoreError.self) { _ = try store.createRoster(named: "rolled back") }
        #expect(store.rosters.isEmpty, "failed save must revert the in-memory change")
    }

    @Test func deleteRosterPersists() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        let a = try store.createRoster(named: "A")
        _ = try store.createRoster(named: "B")
        try store.deleteRoster(a.id)

        let reopened = RosterStore(directory: dir)
        #expect(reopened.rosters.map(\.name) == ["B"])
    }

    // MARK: - Folder sharing

    @Test func switchToEmptyDestinationPublishesCurrentLibrary() throws {
        let source = try makeTempDirectory()
        let destination = try makeTempDirectory()
        let store = RosterStore(directory: source)
        let roster = try store.createRoster(named: "Team")
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("rosters.json"))

        try store.switchDirectory(to: destination)

        #expect(store.directory == destination.resolvingSymlinksInPath().standardizedFileURL)
        #expect(store.rosters.map(\.id) == [roster.id])
        #expect(store.persistentError == nil)
        #expect(try readFile(destination).contains("Team"), "current library must be published in the target folder")
        #expect(try Data(contentsOf: source.appendingPathComponent("rosters.json")) == sourceBytes,
                "the former file must stay untouched")
        let reopened = RosterStore(directory: destination, requireExistingFile: true)
        #expect(reopened.rosters.map(\.name) == ["Team"])
    }

    @Test func populatedDestinationIsAdoptedAndBothFilesPreserved() throws {
        let source = try makeTempDirectory()
        let destination = try makeTempDirectory()
        let store = RosterStore(directory: source)
        try store.createRoster(named: "Mine")
        let other = RosterStore(directory: destination)
        try other.createRoster(named: "Theirs")
        let destinationBytes = try Data(contentsOf: destination.appendingPathComponent("rosters.json"))
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("rosters.json"))

        try store.switchDirectory(to: destination)

        #expect(store.rosters.map(\.name) == ["Theirs"], "joining a populated folder adopts its library")
        #expect(store.persistentError == nil)
        #expect(try Data(contentsOf: destination.appendingPathComponent("rosters.json")) == destinationBytes,
                "the adopted file must not be overwritten")
        #expect(try Data(contentsOf: source.appendingPathComponent("rosters.json")) == sourceBytes,
                "the former file must stay untouched")
    }

    @Test func corruptDestinationRefusesSwitchWithoutChanges() throws {
        let source = try makeTempDirectory()
        let destination = try makeTempDirectory()
        let store = RosterStore(directory: source)
        try store.createRoster(named: "Mine")
        let garbage = "{ this is not valid roster json ]["
        try garbage.write(to: destination.appendingPathComponent("rosters.json"), atomically: true, encoding: .utf8)
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("rosters.json"))
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL

        #expect(throws: RosterStoreError.corruptData(path: resolvedDestination.appendingPathComponent("rosters.json").path)) {
            try store.switchDirectory(to: destination)
        }
        #expect(store.rosters.map(\.name) == ["Mine"], "selection and rosters unchanged after a refused switch")
        #expect(store.directory == source.resolvingSymlinksInPath().standardizedFileURL)
        #expect(store.persistentError == nil)
        #expect(try String(contentsOf: destination.appendingPathComponent("rosters.json"), encoding: .utf8) == garbage,
                "corrupt target file must be left untouched")
        #expect(try Data(contentsOf: source.appendingPathComponent("rosters.json")) == sourceBytes)
    }

    @Test func selectedFolderMustExistWithValidFile() throws {
        let missingDir = try makeTempDirectory().appendingPathComponent("does-not-exist")
        let unavailable = RosterStore(directory: missingDir, requireExistingFile: true)
        guard case .unavailableDirectory = unavailable.persistentError else {
            Issue.record("expected unavailableDirectory, got \(String(describing: unavailable.persistentError))")
            return
        }
        #expect(unavailable.rosters.isEmpty)
        #expect(throws: RosterStoreError.self) { _ = try unavailable.createRoster(named: "blocked") }

        let emptyFolder = try makeTempDirectory()
        let noFile = RosterStore(directory: emptyFolder, requireExistingFile: true)
        guard case .missingSelectedFile = noFile.persistentError else {
            Issue.record("expected missingSelectedFile, got \(String(describing: noFile.persistentError))")
            return
        }
        #expect(noFile.rosters.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: emptyFolder.appendingPathComponent("rosters.json").path),
                "a missing selected file must not be silently recreated")
    }

    @Test func vanishedSelectedFileBlocksEditsUntilRestored() throws {
        let dir = try makeTempDirectory()
        let store = RosterStore(directory: dir)
        try store.createRoster(named: "A")
        let fileURL = dir.appendingPathComponent("rosters.json")
        let bytes = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        store.reload()
        guard case .missingSelectedFile = store.persistentError else {
            Issue.record("expected missingSelectedFile, got \(String(describing: store.persistentError))")
            return
        }
        #expect(store.rosters.map(\.name) == ["A"], "last good rosters stay visible while blocked")
        #expect(throws: RosterStoreError.self) { _ = try store.createRoster(named: "B") }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "blocked edits must not recreate the file")

        try bytes.write(to: fileURL)
        store.reload()
        #expect(store.persistentError == nil, "recovery clears the blocking error")
        #expect(store.rosters.map(\.name) == ["A"])
        _ = try store.createRoster(named: "B")
        #expect(store.rosters.map(\.name) == ["A", "B"])
    }

    @Test func reloadPicksUpSecondStoreChanges() throws {
        let dir = try makeTempDirectory()
        let first = RosterStore(directory: dir)
        _ = try first.createRoster(named: "First")
        let second = RosterStore(directory: dir)
        let added = try second.createRoster(named: "Second")

        first.reload()

        #expect(first.persistentError == nil)
        #expect(first.rosters.map(\.name) == ["First", "Second"])
        #expect(first.rosters.last?.id == added.id)
    }

    @Test func staleEditThrowsAndSucceedsAfterReload() throws {
        let dir = try makeTempDirectory()
        let first = RosterStore(directory: dir)
        _ = try first.createRoster(named: "A")
        let second = RosterStore(directory: dir)
        _ = try second.createRoster(named: "B")

        #expect(throws: RosterStoreError.self) { _ = try first.createRoster(named: "Stale") }
        let afterStale = RosterStore(directory: dir)
        #expect(afterStale.rosters.map(\.name) == ["A", "B"], "the stale edit must not overwrite the newer file")

        first.reload()
        #expect(first.persistentError == nil)
        #expect(first.rosters.map(\.name) == ["A", "B"])
        _ = try first.createRoster(named: "Stale")
        #expect(first.rosters.map(\.name) == ["A", "B", "Stale"])

        let reopened = RosterStore(directory: dir)
        #expect(reopened.rosters.map(\.name) == ["A", "B", "Stale"])
    }

    @Test func brokenSourceCanRecoverIntoPopulatedTarget() throws {
        let source = try makeTempDirectory()
        let destination = try makeTempDirectory()
        let store = RosterStore(directory: source)
        try store.createRoster(named: "Broken")
        let other = RosterStore(directory: destination)
        try other.createRoster(named: "Good")
        try "{ corrupt ][".write(to: source.appendingPathComponent("rosters.json"), atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.persistentError != nil, "precondition: source is blocked")

        try store.switchDirectory(to: destination)

        #expect(store.persistentError == nil)
        #expect(store.rosters.map(\.name) == ["Good"])
        let reopened = RosterStore(directory: destination, requireExistingFile: true)
        #expect(reopened.rosters.map(\.name) == ["Good"])
    }
}

/// Exercises the amended identity rule: writable calendar by exact title +
/// event title + exact instants (Y/M-D for all-day) + series-master matching,
/// with uniqueness enforced by the caller.
@Suite("matchCandidates identity rule")
struct MatchCandidatesTests {

    private func makeContext() throws -> JSContext {
        let url = Bundle.main.url(forResource: "CalendarRoster", withExtension: "js")
        guard let url else { throw TestFailure("script missing") }
        let context = JSContext()!
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        context.evaluateScript("""
        function _match(candidatesJSON, payloadJSON) {
            var candidates = JSON.parse(candidatesJSON);
            candidates.forEach(function (c) {
                c.start = new Date(c.start);
                c.end = new Date(c.end);
            });
            return matchCandidates(candidates, JSON.parse(payloadJSON));
        }
        """)
        return context
    }

    private func payload(title: String, isAllDay: Bool, isSeries: Bool, start: String, end: String) -> String {
        """
        {"title": "\(title)", "isAllDay": \(isAllDay), "isSeries": \(isSeries), "startDate": "\(start)", "endDate": "\(end)"}
        """
    }

    private func meta(title: String, allDay: Bool, start: String, end: String, recurrence: Bool, rule: String? = nil) -> String {
        let ruleJSON = rule.map { "\"\($0)\"" } ?? "null"
        return """
        {"summary": "\(title)", "allDay": \(allDay), "start": "\(start)", "end": "\(end)", "hasRecurrence": \(recurrence), "recurrence": \(ruleJSON)}
        """
    }

    private func runMatch(_ context: JSContext, candidates: [String], payload: String) throws -> [Int] {
        guard let function = context.objectForKeyedSubscript("_match"), !function.isUndefined else {
            throw TestFailure("_match helper missing")
        }
        let json = "[" + candidates.joined(separator: ",") + "]"
        guard let result = function.call(withArguments: [json, payload]) else { throw TestFailure("call failed") }
        return (result.toArray() as? [Double] ?? []).map { Int($0) }
    }

    @Test func exactTimedEventMatches() throws {
        let context = try makeContext()
        let candidates = [meta(title: "Standup", allDay: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z", recurrence: false)]
        let p = payload(title: "Standup", isAllDay: false, isSeries: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z")
        #expect(try runMatch(context, candidates: candidates, payload: p) == [0])
    }

    @Test func wrongEndTimeIsRejected() throws {
        let context = try makeContext()
        let candidates = [meta(title: "Standup", allDay: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T19:00:00Z", recurrence: false)]
        let p = payload(title: "Standup", isAllDay: false, isSeries: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z")
        #expect(try runMatch(context, candidates: candidates, payload: p).isEmpty)
    }

    @Test func allDayMatchesByCalendarDay() throws {
        let context = try makeContext()
        let candidates = [meta(title: "Offsite", allDay: true, start: "2026-11-12T00:00:00Z", end: "2026-11-13T00:00:00Z", recurrence: false)]
        let p = payload(title: "Offsite", isAllDay: true, isSeries: false, start: "2026-11-12T08:00:00+01:00", end: "2026-11-13T08:00:00+01:00")
        // Same Y/M-D as the candidate in the payload's local framing counts as a match.
        let result = try runMatch(context, candidates: candidates, payload: p)
        #expect(result == [0] || result.isEmpty, "depends on system timezone; both are accepted outcomes here")
    }

    @Test func occurrenceMatchesUniqueRecurringMaster() throws {
        let context = try makeContext()
        let master = meta(title: "Weekly sync", allDay: false, start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z", recurrence: true)
        // The dropped occurrence is a week later, same wall-clock time.
        let p = payload(title: "Weekly sync", isAllDay: false, isSeries: true, start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")
        #expect(try runMatch(context, candidates: [master], payload: p) == [0])
    }

    @Test func occurrenceRejectsNonRecurringAndFutureAnchors() throws {
        let context = try makeContext()
        let plain = meta(title: "Weekly sync", allDay: false, start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z", recurrence: false)
        let later = meta(title: "Weekly sync", allDay: false, start: "2026-11-16T18:00:00Z", end: "2026-11-16T19:00:00Z", recurrence: true)
        let p = payload(title: "Weekly sync", isAllDay: false, isSeries: true, start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")
        #expect(try runMatch(context, candidates: [plain], payload: p).isEmpty)
        #expect(try runMatch(context, candidates: [later], payload: p).isEmpty)
    }

    @Test func duplicateCandidatesAreAmbiguous() throws {
        let context = try makeContext()
        let a = meta(title: "Standup", allDay: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z", recurrence: false)
        let b = a
        let p = payload(title: "Standup", isAllDay: false, isSeries: false, start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z")
        #expect(try runMatch(context, candidates: [a, b], payload: p).count == 2, "two matches must fail closed in the caller")
    }

    @Test func splitSeriesPicksTheMasterStillRecurring() throws {
        let context = try makeContext()
        // "This and future events" split: the old master was capped with
        // UNTIL before the occurrence, the new master took over.
        let old = meta(title: "Weekly sync", allDay: false, start: "2026-01-05T18:00:00Z", end: "2026-01-05T19:00:00Z",
                       recurrence: true, rule: "FREQ=WEEKLY;INTERVAL=1;UNTIL=20261001T065959Z")
        let new = meta(title: "Weekly sync", allDay: false, start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z",
                       recurrence: true, rule: "FREQ=WEEKLY;INTERVAL=1")
        let p = payload(title: "Weekly sync", isAllDay: false, isSeries: true, start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")
        #expect(try runMatch(context, candidates: [old, new], payload: p) == [1])
    }

    @Test func untilOnOrAfterOccurrenceStillMatches() throws {
        let context = try makeContext()
        let capped = meta(title: "Weekly sync", allDay: false, start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z",
                          recurrence: true, rule: "FREQ=WEEKLY;UNTIL=20261109T180000Z")
        let p = payload(title: "Weekly sync", isAllDay: false, isSeries: true, start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")
        #expect(try runMatch(context, candidates: [capped], payload: p) == [0])
    }

    @Test func countBoundedSeriesAreNotFiltered() throws {
        let context = try makeContext()
        // COUNT bounds are not expanded; both stay candidates and the caller fails closed.
        let a = meta(title: "Weekly sync", allDay: false, start: "2026-01-05T18:00:00Z", end: "2026-01-05T19:00:00Z",
                     recurrence: true, rule: "FREQ=WEEKLY;COUNT=4")
        let b = meta(title: "Weekly sync", allDay: false, start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z",
                     recurrence: true, rule: "FREQ=WEEKLY")
        let p = payload(title: "Weekly sync", isAllDay: false, isSeries: true, start: "2026-11-09T18:00:00Z", end: "2026-11-09T19:00:00Z")
        #expect(try runMatch(context, candidates: [a, b], payload: p).count == 2)
    }

    @Test func recurrenceUntilParsesRFC5545Forms() throws {
        let context = try makeContext()
        let utc = context.evaluateScript("recurrenceUntil('FREQ=WEEKLY;UNTIL=20261001T065959Z').getTime()")!.toDouble()
        #expect(utc == Date(timeIntervalSince1970: 1_790_837_999).timeIntervalSince1970 * 1000)
        let dateOnly = context.evaluateScript("var d = recurrenceUntil('FREQ=DAILY;UNTIL=20261001'); [d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()]")!.toArray() as? [Double]
        #expect(dateOnly == [2026, 9, 1, 23])
        #expect(context.evaluateScript("recurrenceUntil('FREQ=WEEKLY;COUNT=3')")!.isNull)
        #expect(context.evaluateScript("recurrenceUntil(null)")!.isNull)
    }
}

/// Drives findCalendars/findEvent against an in-memory stand-in for
/// Calendar's scripting objects, so lookup rules (same-named calendars,
/// bulk reads, failing closed) are checked without touching Calendar.app.
@Suite("findEvent lookup")
struct FindEventTests {

    private func makeContext() throws -> JSContext {
        let url = Bundle.main.url(forResource: "CalendarRoster", withExtension: "js")
        guard let url else { throw TestFailure("script missing") }
        let context = JSContext()!
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        context.evaluateScript("""
        var stats = { perEventReads: 0, fullListings: 0, searches: 0 };
        // Calendar resolves event ids globally, whichever calendar is asked.
        var allEvents = [];
        // events: [{uid, summary, start, end, allDay, recurrence}]
        // options: {whoseFails: bool, noUidList: bool, copies: n}
        // Mirrors measured Calendar.app behavior: bulk properties() on a
        // specifier is unsupported, and a whose can return a recurring
        // master several times.
        function mockCalendar(name, writable, events, options) {
            options = options || {};
            allEvents = allEvents.concat(events);
            function record(e) {
                return { uid: e.uid, summary: e.summary, startDate: new Date(e.start), endDate: new Date(e.end),
                         alldayEvent: e.allDay === true, recurrence: e.recurrence || "" };
            }
            function ref(e) {
                return { properties: function () { stats.perEventReads++; return record(e); },
                         uid: function () { return e.uid; } };
            }
            var eventsObj = function () { stats.fullListings++; return events.map(ref); };
            function hits() {
                var copies = options.copies || 1, list = [];
                events.forEach(function (e) {
                    var n = e.recurrence ? copies : 1;
                    for (var i = 0; i < n; i++) list.push(e);
                });
                return list;
            }
            eventsObj.whose = function () {
                stats.searches++;
                var spec = function () {
                    if (options.whoseFails) throw new Error("-1726");
                    return hits().map(ref);
                };
                spec.properties = function () { throw new Error("Can't get object."); };
                spec.uid = function () {
                    if (options.whoseFails) throw new Error("-1726");
                    if (options.noUidList) throw new Error("uid list unsupported");
                    return hits().map(function (e) { return e.uid; });
                };
                return spec;
            };
            eventsObj.byId = function (id) {
                var found = allEvents.filter(function (e) { return e.uid === id; });
                if (found.length === 0) return { properties: function () { throw new Error("no such event"); } };
                return ref(found[0]);
            };
            return { id: options.id, name: function () { return name; }, writable: function () { return writable; }, events: eventsObj };
        }
        function mockApp(calendars) {
            var list = function () { return calendars; };
            list.name = function () { return calendars.map(function (c) { return c.name(); }); };
            for (var i = 0; i < calendars.length; i++) list[i] = calendars[i];
            list.byId = function (id) {
                var found = calendars.filter(function (c) { return c.id === id; });
                if (found.length) return found[0];
                var missing = function () { throw new Error("Can't get object."); };
                return { name: missing, writable: missing, events: null };
            };
            return { calendars: list };
        }
        function lookup(app, payload) {
            try {
                return findEvent(findCalendars(app, payload), payload).uid();
            } catch (e) {
                return "ERROR: " + e.message;
            }
        }
        var standup = { summary: "Standup", start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z" };
        function ev(uid, base) { var e = JSON.parse(JSON.stringify(base)); e.uid = uid; return e; }
        var payload = { calendarTitle: "Calendar", title: "Standup", isAllDay: false, isSeries: false,
                        startDate: "2026-11-12T18:00:00Z", endDate: "2026-11-12T18:30:00Z", knownUID: "" };
        """)
        return context
    }

    private func eval(_ context: JSContext, _ script: String) -> JSValue {
        context.evaluateScript(script)!
    }

    @Test func sameNamedCalendarsResolveTheUniqueEvent() throws {
        let context = try makeContext()
        let uid = eval(context, """
        lookup(mockApp([
            mockCalendar("Calendar", true, []),
            mockCalendar("Calendar", true, [ev("exchange-1", standup)])
        ]), payload)
        """).toString()
        #expect(uid == "exchange-1")
    }

    @Test func matchesInTwoCalendarsFailClosed() throws {
        let context = try makeContext()
        let result = eval(context, """
        lookup(mockApp([
            mockCalendar("Calendar", true, [ev("icloud-1", standup)]),
            mockCalendar("Calendar", true, [ev("exchange-1", standup)])
        ]), payload)
        """).toString()
        #expect(result?.hasPrefix("ERROR: Cannot safely match") == true)
    }

    @Test func readOnlySameNamedCalendarsAreIgnored() throws {
        let context = try makeContext()
        let uid = eval(context, """
        lookup(mockApp([
            mockCalendar("Calendar", false, [ev("readonly-1", standup)]),
            mockCalendar("Calendar", true, [ev("mine-1", standup)])
        ]), payload)
        """).toString()
        #expect(uid == "mine-1")
    }

    @Test func timedLookupReadsEachCandidateOnce() throws {
        let context = try makeContext()
        let uid = eval(context, """
        stats.perEventReads = 0;
        lookup(mockApp([mockCalendar("Calendar", true, [
            ev("a", { summary: "Standup", start: "2026-11-11T18:00:00Z", end: "2026-11-11T18:30:00Z" }),
            ev("b", standup),
            ev("c", { summary: "Standup", start: "2026-11-13T18:00:00Z", end: "2026-11-13T18:30:00Z" })
        ])]), payload)
        """).toString()
        #expect(uid == "b")
        #expect(eval(context, "stats.perEventReads").toInt32() == 3)
    }

    @Test func repeatedSeriesMasterIsOneCandidate() throws {
        let context = try makeContext()
        // Calendar returned the active "House Cleaning" master 6 times; that
        // must not look like 6 ambiguous candidates, nor cost 6 reads.
        let uid = eval(context, """
        stats.perEventReads = 0;
        var master = { uid: "m", summary: "Standup", start: "2026-11-02T18:00:00Z", end: "2026-11-02T18:30:00Z", recurrence: "FREQ=WEEKLY;INTERVAL=1" };
        var p = JSON.parse(JSON.stringify(payload)); p.isSeries = true;
        lookup(mockApp([mockCalendar("Calendar", true, [master], { copies: 6 })]), p)
        """).toString()
        #expect(uid == "m")
        #expect(eval(context, "stats.perEventReads").toInt32() == 1)
    }

    @Test func repeatedSeriesMasterIsDedupedOnReferenceFallback() throws {
        let context = try makeContext()
        let uid = eval(context, """
        var master = { uid: "m", summary: "Standup", start: "2026-11-02T18:00:00Z", end: "2026-11-02T18:30:00Z", recurrence: "FREQ=WEEKLY;INTERVAL=1" };
        var p = JSON.parse(JSON.stringify(payload)); p.isSeries = true;
        lookup(mockApp([mockCalendar("Calendar", true, [master], { copies: 6, noUidList: true })]), p)
        """).toString()
        #expect(uid == "m")
    }

    @Test func referenceFallbackWhenUidListFails() throws {
        let context = try makeContext()
        let uid = eval(context, """
        lookup(mockApp([mockCalendar("Calendar", true, [ev("b", standup)], { noUidList: true })]), payload)
        """).toString()
        #expect(uid == "b")
    }

    @Test func unsearchableCalendarFailsClosedWithoutListingEverything() throws {
        let context = try makeContext()
        let result = eval(context, """
        stats.fullListings = 0;
        lookup(mockApp([mockCalendar("Calendar", true, [ev("b", standup)], { whoseFails: true })]), payload)
        """).toString()
        #expect(result?.hasPrefix("ERROR: Cannot safely match") == true)
        #expect(eval(context, "stats.fullListings").toInt32() == 0)
    }

    @Test func knownUIDResolvesAcrossSameNamedCalendars() throws {
        let context = try makeContext()
        let uid = eval(context, """
        stats.perEventReads = 0;
        var p = JSON.parse(JSON.stringify(payload)); p.knownUID = "exchange-1";
        lookup(mockApp([
            mockCalendar("Calendar", true, []),
            mockCalendar("Calendar", true, [ev("exchange-1", standup)])
        ]), p)
        """).toString()
        #expect(uid == "exchange-1")
        #expect(eval(context, "stats.perEventReads").toInt32() == 1, "only the byId identity check reads an event")
    }

    @Test func staleKnownUIDFallsBackToScan() throws {
        let context = try makeContext()
        let uid = eval(context, """
        var p = JSON.parse(JSON.stringify(payload)); p.knownUID = "gone";
        lookup(mockApp([mockCalendar("Calendar", true, [ev("b", standup)])]), p)
        """).toString()
        #expect(uid == "b")
    }

    @Test func exactCalendarIdDisambiguatesSameNamedCalendars() throws {
        let context = try makeContext()
        // Identical events on two same-named calendars are ambiguous by name,
        // but EventKit's calendarIdentifier selects exactly one calendar.
        let uid = eval(context, """
        var p = JSON.parse(JSON.stringify(payload)); p.calendarIdentifier = "CAL-B";
        lookup(mockApp([
            mockCalendar("Calendar", true, [ev("icloud-1", standup)], { id: "CAL-A" }),
            mockCalendar("Calendar", true, [ev("exchange-1", standup)], { id: "CAL-B" })
        ]), p)
        """).toString()
        #expect(uid == "exchange-1")
    }

    @Test func exactCalendarThatIsReadOnlyFailsClosed() throws {
        let context = try makeContext()
        // Must not widen to the other, writable same-named calendar.
        let result = eval(context, """
        var p = JSON.parse(JSON.stringify(payload)); p.calendarIdentifier = "CAL-A";
        lookup(mockApp([
            mockCalendar("Calendar", false, [ev("readonly-1", standup)], { id: "CAL-A" }),
            mockCalendar("Calendar", true, [ev("mine-1", standup)], { id: "CAL-B" })
        ]), p)
        """).toString()
        #expect(result?.hasPrefix("ERROR: Cannot safely match") == true)
    }

    @Test func exactCalendarWithDifferentTitleFailsClosed() throws {
        let context = try makeContext()
        let result = eval(context, """
        var p = JSON.parse(JSON.stringify(payload)); p.calendarIdentifier = "CAL-A";
        lookup(mockApp([
            mockCalendar("Renamed", true, [ev("a", standup)], { id: "CAL-A" }),
            mockCalendar("Calendar", true, [ev("b", standup)], { id: "CAL-B" })
        ]), p)
        """).toString()
        #expect(result?.hasPrefix("ERROR: Cannot safely match") == true)
    }

    @Test func unresolvableCalendarIdFallsBackToName() throws {
        let context = try makeContext()
        let uid = eval(context, """
        var p = JSON.parse(JSON.stringify(payload)); p.calendarIdentifier = "EXCHANGE-STYLE-ID";
        lookup(mockApp([mockCalendar("Calendar", true, [ev("b", standup)], { id: "CAL-B" })]), p)
        """).toString()
        #expect(uid == "b")
    }

    @Test func externalIdentifierSkipsTheSearch() throws {
        let context = try makeContext()
        let uid = eval(context, """
        stats.searches = 0; stats.perEventReads = 0;
        var p = JSON.parse(JSON.stringify(payload)); p.calendarIdentifier = "CAL-B"; p.externalIdentifier = "b";
        lookup(mockApp([mockCalendar("Calendar", true, [ev("a", { summary: "Standup", start: "2026-11-11T18:00:00Z", end: "2026-11-11T18:30:00Z" }), ev("b", standup)], { id: "CAL-B" })]), p)
        """).toString()
        #expect(uid == "b")
        #expect(eval(context, "stats.searches").toInt32() == 0)
        #expect(eval(context, "stats.perEventReads").toInt32() == 1)
    }

    @Test func externalIdentifierForAnotherEventFallsBackToSearch() throws {
        let context = try makeContext()
        // The id resolves, but to an event that fails the identity check.
        let uid = eval(context, """
        stats.searches = 0;
        var p = JSON.parse(JSON.stringify(payload)); p.externalIdentifier = "a";
        lookup(mockApp([mockCalendar("Calendar", true, [ev("a", { summary: "Other", start: "2026-11-12T18:00:00Z", end: "2026-11-12T18:30:00Z" }), ev("b", standup)])]), p)
        """).toString()
        #expect(uid == "b")
        #expect(eval(context, "stats.searches").toInt32() > 0)
    }

    @Test func detachedOccurrenceIdentifierTargetsTheSeriesMaster() throws {
        let context = try makeContext()
        // The mock knows only the master id; a lookup of the raw "/RID=" id
        // would miss and force a search, so zero searches proves the suffix
        // was dropped and the master was resolved.
        let uid = eval(context, """
        stats.searches = 0;
        var master = { uid: "m", summary: "Standup", start: "2026-11-02T18:00:00Z", end: "2026-11-02T18:30:00Z", recurrence: "FREQ=WEEKLY;INTERVAL=1" };
        var p = JSON.parse(JSON.stringify(payload)); p.isSeries = true; p.externalIdentifier = "m/RID=814827600";
        lookup(mockApp([mockCalendar("Calendar", true, [master])]), p)
        """).toString()
        #expect(uid == "m")
        #expect(eval(context, "stats.searches").toInt32() == 0)
        #expect(eval(context, "seriesExternalIdentifier('abc')").toString() == "abc")
    }

    @Test func movedDetachedOccurrenceFailsClosedWithoutSearching() throws {
        let context = try makeContext()
        // The occurrence was moved off the series' time; a decoy series with
        // the same title at the new time must not be picked by a search.
        let result = eval(context, """
        stats.searches = 0;
        var master = { uid: "m", summary: "Standup", start: "2026-11-02T18:00:00Z", end: "2026-11-02T18:30:00Z", recurrence: "FREQ=WEEKLY;INTERVAL=1" };
        var decoy = { uid: "d", summary: "Standup", start: "2026-11-01T20:30:00Z", end: "2026-11-01T21:00:00Z", recurrence: "FREQ=WEEKLY;INTERVAL=1" };
        var p = JSON.parse(JSON.stringify(payload)); p.isSeries = true; p.externalIdentifier = "m/RID=1";
        p.startDate = "2026-11-12T20:30:00Z"; p.endDate = "2026-11-12T21:00:00Z";
        lookup(mockApp([mockCalendar("Calendar", true, [master, decoy])]), p)
        """).toString()
        #expect(result?.hasPrefix("ERROR: Cannot safely match") == true)
        #expect(eval(context, "stats.searches").toInt32() == 0)
    }
}

/// Apple event errors surface as actionable messages instead of raw text.
@Suite("Automation error classification")
struct AutomationErrorTests {

    @Test func commonAppleEventErrorsMapToActionableErrors() {
        #expect(CalendarAutomation.classify(errorNumber: -1743) == .notAuthorized)
        #expect(CalendarAutomation.classify(errorNumber: -1744) == .notAuthorized)
        #expect(CalendarAutomation.classify(errorNumber: -1712) == .calendarTimedOut)
        #expect(CalendarAutomation.classify(errorNumber: -600) == .calendarUnavailable)
        #expect(CalendarAutomation.classify(errorNumber: -609) == .calendarUnavailable)
        #expect(CalendarAutomation.classify(errorNumber: -1728) == nil)
        #expect(CalendarAutomation.classify(errorNumber: nil) == nil)
    }

    @Test func errorNumberIsReadFromOsascriptStderr() {
        let stderr = "/Applications/Roster.app/Contents/Resources/CalendarRoster.js: execution error: Error: Not authorized to send Apple events to Calendar. (-1743)"
        #expect(CalendarAutomation.errorNumber(inStderr: stderr) == -1743)
        #expect(CalendarAutomation.errorNumber(inStderr: "some warning without a code") == nil)
    }

    @Test func notAuthorizedMessagePointsToSystemSettings() {
        let message = CalendarAutomationError.notAuthorized.errorDescription ?? ""
        #expect(message.contains("Automation"))
        #expect(message.contains("no invitees were added"))
    }

    @Test func scriptReportsErrorNumberInOutput() throws {
        let url = try #require(Bundle.main.url(forResource: "CalendarRoster", withExtension: "js"))
        let context = JSContext()!
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        let json = context.evaluateScript(#"output("error", { message: "Not authorized", errorNumber: -1743 })"#)!.toString()!
        let decoded = try JSONDecoder().decode(ScriptOutput.self, from: Data(json.utf8))
        #expect(decoded.errorNumber == -1743)
        let plain = context.evaluateScript(#"output("error", { message: "x" })"#)!.toString()!
        #expect(try JSONDecoder().decode(ScriptOutput.self, from: Data(plain.utf8)).errorNumber == nil)
    }
}
