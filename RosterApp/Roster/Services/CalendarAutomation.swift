import AppKit
import Foundation

/// The only attendee-mutation path: a background `osascript` process talking
/// to Calendar.app. EventKit is never used for writes.
nonisolated enum CalendarAutomationError: LocalizedError, Equatable {
    case scriptUnavailable
    case scriptFailed(message: String)
    case identityMismatch
    case unconfirmed
    case invalidOutput(String)
    case alreadyRunning
    case payloadEncodingFailed
    /// Automation → Calendar is denied (or still needs consent).
    case notAuthorized
    /// Calendar did not answer in time (Apple event timeout or our watchdog).
    case calendarTimedOut
    /// Calendar quit or the connection to it broke mid-run.
    case calendarUnavailable

    var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            return "The Calendar automation script is missing from the app bundle."
        case .scriptFailed(let message):
            return message
        case .identityMismatch:
            return "Cannot safely match this event in Calendar; no invitees were added"
        case .unconfirmed:
            return "Calendar did not confirm the update. Check the event before trying again."
        case .invalidOutput(let detail):
            return "Calendar automation returned unreadable output: \(detail)"
        case .alreadyRunning:
            return "Another calendar update is already running."
        case .payloadEncodingFailed:
            return "Could not encode the automation request."
        case .notAuthorized:
            return "Roster isn't allowed to control Calendar, so no invitees were added. Turn on Calendar under Roster in System Settings › Privacy & Security › Automation, then try again."
        case .calendarTimedOut:
            return "Calendar didn't respond in time. If it's busy syncing, wait a moment and try again."
        case .calendarUnavailable:
            return "Roster lost its connection to Calendar. Open Calendar and try again."
        }
    }
}

/// A review produced by a preview and confirmed by the user. `required` is the
/// roster snapshot at preview time; `missingKeys` are normalized email keys in
/// required-member order. `locatedUID` is the Calendar-scripting uid captured
/// by the concurrent read-only locate run (nil until it finishes); it lets
/// apply resolve the event by id instead of rescanning the calendar.
nonisolated struct Review: Sendable {
    let event: EventSnapshot
    let rosterID: UUID
    let required: [Invitee]
    let missingKeys: [String]
    let isSeries: Bool
    let locatedUID: String?

    /// Human-readable rows for the dialog: names/emails of missing invitees.
    var missingInvitees: [Invitee] {
        missingKeys.compactMap { key in
            required.first { normalizedEmailKey($0.email) == key }
        }
    }

    func withLocatedUID(_ uid: String) -> Review {
        Review(
            event: event,
            rosterID: rosterID,
            required: required,
            missingKeys: missingKeys,
            isSeries: isSeries,
            locatedUID: uid
        )
    }
}

nonisolated enum ApplyResult: Sendable {
    /// Something changed (event or roster) between preview and apply; re-review.
    case changed(Review)
    case finished(added: [String], remaining: [String], warning: String?)
}

nonisolated struct ScriptOutput: Decodable, Equatable {
    let status: String
    let attendeeEmails: [String]?
    let missingKeys: [String]?
    let isSeries: Bool?
    let addedEmails: [String]?
    let remainingEmails: [String]?
    let warning: String?
    let message: String?
    /// Apple event error number behind a script "error" status, if any.
    let errorNumber: Int?
    /// Calendar-scripting uid, returned by the locate mode.
    let uid: String?
}

nonisolated func normalizedEmailKey(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("mailto:") { value.removeFirst("mailto:".count) }
    return value.isEmpty ? nil : value
}

/// Swift twin of the script's `missingEmailKeys`: required emails minus
/// already-present attendee emails. Comparison is trimmed/lowercased with any
/// "mailto:" prefix stripped; output keeps the required order and
/// deduplicates by normalized key.
nonisolated func missingKeys(required: [String], attendeeEmails: [String]) -> [String] {
    var attendeeKeys = Set<String>()
    for email in attendeeEmails {
        if let key = normalizedEmailKey(email) { attendeeKeys.insert(key) }
    }
    var seen = Set<String>()
    var missing: [String] = []
    for email in required {
        guard let key = normalizedEmailKey(email), !seen.contains(key) else { continue }
        seen.insert(key)
        if !attendeeKeys.contains(key) { missing.append(key) }
    }
    return missing
}

@MainActor
final class CalendarAutomation {
    static let shared = CalendarAutomation()
    /// True while a mutation subprocess runs; the UI disables repeated Confirm.
    private(set) var busy = false

    func preview(event: EventSnapshot, roster: Roster) async throws -> Review {
        let payload = try makePayload(
            mode: "preview",
            event: event,
            requiredEmails: roster.members.map(\.email),
            reviewedMissingKeys: [],
            knownUID: ""
        )
        let output = try await execute(payload: payload)
        guard output.status == "preview" else {
            throw error(for: output, default: .invalidOutput("preview returned status \(output.status)"))
        }
        return Review(
            event: event,
            rosterID: roster.id,
            required: roster.members,
            missingKeys: output.missingKeys ?? [],
            isSeries: output.isSeries ?? event.isSeries,
            locatedUID: nil
        )
    }

    /// Read-only identity resolution for the fast apply path: resolves the
    /// event conservatively (findEvent) and returns its Calendar-scripting
    /// uid, so a later apply can use byId instead of rescanning. Runs without
    /// the busy guard — it never writes, and it overlaps the review dialog.
    func locate(event: EventSnapshot) async throws -> String? {
        let payload = try makePayload(
            mode: "locate",
            event: event,
            requiredEmails: [],
            reviewedMissingKeys: [],
            knownUID: ""
        )
        let output = try await execute(payload: payload)
        guard output.status == "located" else {
            throw error(for: output, default: .invalidOutput("locate returned status \(output.status)"))
        }
        let uid = output.uid ?? ""
        return uid.isEmpty ? nil : uid
    }

    /// `currentAttendees` reads the event's attendee emails in-process
    /// (EventKit); it is only used for read-only verification after an apply
    /// attempt went wrong, and may return nil when the list is unknown.
    func apply(review: Review, currentAttendees: @MainActor () -> [String]? = { nil }) async throws -> ApplyResult {
        guard !busy else { throw CalendarAutomationError.alreadyRunning }
        busy = true
        defer { busy = false }

        let payload = try makePayload(
            mode: "apply",
            event: review.event,
            requiredEmails: review.required.map(\.email),
            reviewedMissingKeys: review.missingKeys,
            knownUID: review.locatedUID ?? ""
        )
        do {
            let output = try await execute(payload: payload)
            switch output.status {
            case "changed":
                return .changed(Review(
                    event: review.event,
                    rosterID: review.rosterID,
                    required: review.required,
                    missingKeys: output.missingKeys ?? [],
                    isSeries: output.isSeries ?? review.isSeries,
                    locatedUID: review.locatedUID
                ))
            case "finished":
                return .finished(
                    added: output.addedEmails ?? [],
                    remaining: output.remainingEmails ?? [],
                    warning: output.warning
                )
            case "error":
                // The subprocess already attempted (and partially performed) a
                // write it could not complete cleanly. Follow up read-only.
                return try await recoverAfterFailedApply(review: review, currentAttendees: currentAttendees)
            default:
                throw CalendarAutomationError.invalidOutput("apply returned status \(output.status)")
            }
        } catch let transport as CalendarAutomationError {
            // Transport failures (timeout, crash, unreadable output) are
            // uncertain partial writes: exactly one read-only preview, never a
            // second write.
            switch transport {
            case .scriptFailed, .invalidOutput, .scriptUnavailable, .unconfirmed,
                 .calendarTimedOut, .calendarUnavailable:
                return try await recoverAfterFailedApply(review: review, currentAttendees: currentAttendees)
            default:
                throw transport
            }
        }
    }

    // MARK: - Failure recovery (read-only)

    /// After an apply attempt went wrong, report what is actually on the
    /// event now. This never writes. EventKit answers in-process first, so a
    /// Calendar.app that just timed out is not asked to rescan; only when
    /// EventKit cannot confirm every reviewed address does one script preview
    /// run, resolving the event by its located uid when known.
    private func recoverAfterFailedApply(review: Review, currentAttendees: @MainActor () -> [String]?) async throws -> ApplyResult {
        func split(_ emails: [String]) -> (added: [String], remaining: [String]) {
            let present = Set(emails.compactMap(normalizedEmailKey))
            var added: [String] = []
            var remaining: [String] = []
            for key in review.missingKeys {
                if present.contains(key) { added.append(key) } else { remaining.append(key) }
            }
            return (added, remaining)
        }

        let eventKitEmails = currentAttendees()
        if let eventKitEmails {
            let result = split(eventKitEmails)
            if result.remaining.isEmpty {
                return .finished(
                    added: result.added,
                    remaining: [],
                    warning: "Calendar automation reported a problem, but every invitee is now on the event."
                )
            }
        }

        let previewPayload = try makePayload(
            mode: "preview",
            event: review.event,
            requiredEmails: review.required.map(\.email),
            reviewedMissingKeys: [],
            knownUID: review.locatedUID ?? ""
        )
        if let output = try? await execute(payload: previewPayload), output.status == "preview" {
            let result = split(output.attendeeEmails ?? [])
            return .finished(added: result.added, remaining: result.remaining, warning: CalendarAutomationError.unconfirmed.errorDescription)
        }
        if let eventKitEmails {
            // EventKit may lag a write Calendar just made, so its "still
            // missing" is reported as unconfirmed, never as a definite miss.
            let result = split(eventKitEmails)
            return .finished(added: result.added, remaining: result.remaining, warning: CalendarAutomationError.unconfirmed.errorDescription)
        }
        throw CalendarAutomationError.unconfirmed
    }

    // MARK: - Error classification

    /// Maps the Apple event errors users actually hit to actionable errors;
    /// nil means "no specific advice", and callers keep their generic error.
    nonisolated static func classify(errorNumber: Int?) -> CalendarAutomationError? {
        switch errorNumber {
        case -1743, -1744: // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
            return .notAuthorized
        case -1712: // errAETimeout
            return .calendarTimedOut
        case -600, -609, -903: // procNotFound, connectionInvalid, noPortErr
            return .calendarUnavailable
        default:
            return nil
        }
    }

    /// osascript reports errors that escape the script as
    /// "…: execution error: <message> (-1743)"; this pulls out the number.
    nonisolated static func errorNumber(inStderr stderr: String) -> Int? {
        guard let match = stderr.firstMatch(of: /\((-\d+)\)\s*$/) else { return nil }
        return Int(match.1)
    }

    // MARK: - Calendar warm-up

    private static let calendarBundleIdentifier = "com.apple.iCal"

    /// Starts Calendar.app hidden in the background when it isn't running,
    /// so the first drop doesn't pay its multi-second cold launch inside the
    /// automation run. A Calendar the user already has open is left alone.
    /// Launching needs no Automation permission and sends no Apple events.
    func warmUpCalendarApp() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.calendarBundleIdentifier).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.calendarBundleIdentifier) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    // MARK: - Subprocess plumbing

    nonisolated private static func scriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "CalendarRoster", withExtension: "js", subdirectory: "Scripts") {
            return bundled
        }
        return Bundle.main.url(forResource: "CalendarRoster", withExtension: "js")
    }

    nonisolated private struct ScriptRunResult {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
        let timedOut: Bool
    }

    private func makePayload(mode: String, event: EventSnapshot, requiredEmails: [String], reviewedMissingKeys: [String], knownUID: String) throws -> ScriptPayload {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard !event.eventIdentifier.isEmpty, !event.calendarTitle.isEmpty else {
            throw CalendarAutomationError.identityMismatch
        }
        return ScriptPayload(
            mode: mode,
            calendarTitle: event.calendarTitle,
            title: event.title,
            startDate: formatter.string(from: event.startDate),
            endDate: formatter.string(from: event.endDate),
            isAllDay: event.isAllDay,
            isSeries: event.isSeries,
            requiredEmails: requiredEmails,
            reviewedMissingKeys: reviewedMissingKeys,
            knownUID: knownUID,
            calendarIdentifier: event.calendarIdentifier,
            externalIdentifier: event.calendarItemExternalIdentifier
        )
    }

    nonisolated private struct ScriptPayload: Encodable {
        let mode: String
        let calendarTitle: String
        let title: String
        let startDate: String
        let endDate: String
        let isAllDay: Bool
        let isSeries: Bool
        let requiredEmails: [String]
        let reviewedMissingKeys: [String]
        let knownUID: String
        /// EventKit calendarIdentifier; equals Calendar's scripting
        /// calendar id, so the script can select the calendar exactly.
        let calendarIdentifier: String
        /// EventKit calendarItemExternalIdentifier (the iCalendar UID);
        /// Calendar's byId accepts it, letting the script skip its scan.
        /// Always verified by the identity check.
        let externalIdentifier: String
    }

    private func execute(payload: ScriptPayload) async throws -> ScriptOutput {
        guard let scriptURL = Self.scriptURL() else { throw CalendarAutomationError.scriptUnavailable }
        let encoder = JSONEncoder()
        guard let payloadData = try? encoder.encode(payload) else {
            throw CalendarAutomationError.payloadEncodingFailed
        }
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)

        let run = try await Self.runScript(scriptURL: scriptURL, payloadJSON: payloadJSON)
        try Task.checkCancellation()
        if run.timedOut {
            throw CalendarAutomationError.calendarTimedOut
        }
        // A clean exit with well-formed stdout is authoritative: osascript
        // and JavaScriptCore sometimes print benign warnings to stderr, and
        // treating those as failures turned successful writes into
        // "unconfirmed" recoveries. stderr only explains real failures.
        let decoded = run.stdout.data(using: .utf8).flatMap { try? JSONDecoder().decode(ScriptOutput.self, from: $0) }
        guard run.exitStatus == 0, let output = decoded else {
            let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mapped = Self.classify(errorNumber: Self.errorNumber(inStderr: stderr)) {
                throw mapped
            }
            if run.exitStatus != 0 || !stderr.isEmpty {
                throw CalendarAutomationError.scriptFailed(
                    message: stderr.isEmpty ? "Calendar automation exited with status \(run.exitStatus)." : stderr
                )
            }
            throw CalendarAutomationError.invalidOutput("stdout was not the expected JSON")
        }
        guard output.status != "error" else {
            throw error(for: output, default: .scriptFailed(message: output.message ?? "Unknown Calendar automation error"))
        }
        return output
    }

    private func error(for output: ScriptOutput, default fallback: CalendarAutomationError) -> CalendarAutomationError {
        if let mapped = Self.classify(errorNumber: output.errorNumber) {
            return mapped
        }
        let message = output.message ?? ""
        if message.contains("Cannot safely match this event in Calendar") {
            return .identityMismatch
        }
        return fallback
    }

    /// Holds the running process so task cancellation can terminate it.
    nonisolated private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Records a started process; false means cancellation already
        /// happened and the caller must terminate it.
        func attach(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Runs the script in a detached task (never on the main actor). stdout and
    /// stderr are drained concurrently so the pipes cannot deadlock, and the
    /// process is terminated after the timeout or when the calling task is
    /// cancelled — an abandoned read-only run must not keep Calendar.app
    /// busy, because Calendar serves Apple events one at a time and every
    /// later run would queue behind it.
    nonisolated private static func runScript(scriptURL: URL, payloadJSON: String, timeoutSeconds: Int = 120) async throws -> ScriptRunResult {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func set() {
                lock.lock(); value = true; lock.unlock()
            }
        }

        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", scriptURL.path, payloadJSON]
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                try process.run()
                if !handle.attach(process) { process.terminate() }

                let timedOut = Flag()
                let watchdog = Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    if !Task.isCancelled {
                        timedOut.set()
                        if process.isRunning { process.terminate() }
                    }
                }

                @Sendable func drain(_ handle: FileHandle) async -> Data {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: handle.readDataToEndOfFile())
                        }
                    }
                }
                async let stdoutData = drain(stdoutPipe.fileHandleForReading)
                async let stderrData = drain(stderrPipe.fileHandleForReading)
                let out = await stdoutData
                let err = await stderrData
                watchdog.cancel()
                process.waitUntilExit()
                return ScriptRunResult(
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    exitStatus: process.terminationStatus,
                    timedOut: timedOut.isSet
                )
            }.value
        } onCancel: {
            handle.cancel()
        }
    }
}
