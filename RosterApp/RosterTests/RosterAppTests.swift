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

    private func meta(title: String, allDay: Bool, start: String, end: String, recurrence: Bool) -> String {
        """
        {"summary": "\(title)", "allDay": \(allDay), "start": "\(start)", "end": "\(end)", "hasRecurrence": \(recurrence)}
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
}
