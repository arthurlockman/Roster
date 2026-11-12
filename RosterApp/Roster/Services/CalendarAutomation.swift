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
        }
    }
}

/// A review produced by a preview and confirmed by the user. `required` is the
/// roster snapshot at preview time; `missingKeys` are normalized email keys in
/// required-member order.
nonisolated struct Review: Sendable {
    let event: EventSnapshot
    let rosterID: UUID
    let required: [Invitee]
    let missingKeys: [String]
    let isSeries: Bool

    /// Human-readable rows for the dialog: names/emails of missing invitees.
    var missingInvitees: [Invitee] {
        missingKeys.compactMap { key in
            required.first { normalizedEmailKey($0.email) == key }
        }
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
}

nonisolated func normalizedEmailKey(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("mailto:") { value.removeFirst("mailto:".count) }
    return value.isEmpty ? nil : value
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
            reviewedMissingKeys: []
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
            isSeries: output.isSeries ?? event.isSeries
        )
    }

    func apply(review: Review) async throws -> ApplyResult {
        guard !busy else { throw CalendarAutomationError.alreadyRunning }
        busy = true
        defer { busy = false }

        let payload = try makePayload(
            mode: "apply",
            event: review.event,
            requiredEmails: review.required.map(\.email),
            reviewedMissingKeys: review.missingKeys
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
                    isSeries: output.isSeries ?? review.isSeries
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
                return try await recoverAfterFailedApply(review: review)
            default:
                throw CalendarAutomationError.invalidOutput("apply returned status \(output.status)")
            }
        } catch let transport as CalendarAutomationError {
            // Transport failures (timeout, crash, unreadable output) are
            // uncertain partial writes: exactly one read-only preview, never a
            // second write.
            switch transport {
            case .scriptFailed, .invalidOutput, .scriptUnavailable, .unconfirmed:
                return try await recoverAfterFailedApply(review: review)
            default:
                throw transport
            }
        }
    }

    // MARK: - Failure recovery (read-only)

    /// After an apply attempt went wrong, run one preview and report what is
    /// actually on the event now. This never writes.
    private func recoverAfterFailedApply(review: Review) async throws -> ApplyResult {
        let previewPayload = try makePayload(
            mode: "preview",
            event: review.event,
            requiredEmails: review.required.map(\.email),
            reviewedMissingKeys: []
        )
        guard let output = try? await execute(payload: previewPayload), output.status == "preview" else {
            throw CalendarAutomationError.unconfirmed
        }
        let attendees = Set((output.attendeeEmails ?? []).compactMap(normalizedEmailKey))
        var added: [String] = []
        var remaining: [String] = []
        for key in review.missingKeys {
            if attendees.contains(key) { added.append(key) } else { remaining.append(key) }
        }
        return .finished(added: added, remaining: remaining, warning: CalendarAutomationError.unconfirmed.errorDescription)
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

    private func makePayload(mode: String, event: EventSnapshot, requiredEmails: [String], reviewedMissingKeys: [String]) throws -> ScriptPayload {
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
            reviewedMissingKeys: reviewedMissingKeys
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
    }

    private func execute(payload: ScriptPayload) async throws -> ScriptOutput {
        guard let scriptURL = Self.scriptURL() else { throw CalendarAutomationError.scriptUnavailable }
        let encoder = JSONEncoder()
        guard let payloadData = try? encoder.encode(payload) else {
            throw CalendarAutomationError.payloadEncodingFailed
        }
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)

        let run = try await Self.runScript(scriptURL: scriptURL, payloadJSON: payloadJSON)
        if run.timedOut || run.exitStatus != 0 || !run.stderr.isEmpty {
            // Nonzero exit/stderr/timeout are errors even if stdout parsed.
            throw CalendarAutomationError.scriptFailed(
                message: run.timedOut
                    ? "Calendar automation timed out after 120 seconds."
                    : (run.stderr.isEmpty ? "Calendar automation exited with status \(run.exitStatus)." : run.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        guard let data = run.stdout.data(using: .utf8),
              let output = try? JSONDecoder().decode(ScriptOutput.self, from: data) else {
            throw CalendarAutomationError.invalidOutput("stdout was not the expected JSON")
        }
        guard output.status != "error" else {
            throw error(for: output, default: .scriptFailed(message: output.message ?? "Unknown Calendar automation error"))
        }
        return output
    }

    private func error(for output: ScriptOutput, default fallback: CalendarAutomationError) -> CalendarAutomationError {
        let message = output.message ?? ""
        if message.contains("Cannot safely match this event in Calendar") {
            return .identityMismatch
        }
        return fallback
    }

    /// Runs the script in a detached task (never on the main actor). stdout and
    /// stderr are drained concurrently so the pipes cannot deadlock, and the
    /// process is terminated after the timeout.
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

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", scriptURL.path, payloadJSON]
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()

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
    }
}
