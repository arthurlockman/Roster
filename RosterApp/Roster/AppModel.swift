import Foundation
import Observation
import SwiftUI
/// Coordinates the drag → preview → review → apply flow. No write ever happens
/// without a preview shown to the user first.
@Observable
final class AppModel {
    let rosterStore: RosterStore
    let contactsService: ContactsService
    let calendarService: CalendarService
    let automation: CalendarAutomation

    /// UserDefaults key for the chosen rosters.json folder. Absent means
    /// the default Application Support location.
    static let storageDirectoryKey = "rosterStorageDirectory"

    enum Flow {
        case idle
        /// Dropped on a changed occurrence: asking whether to edit just that
        /// occurrence or the whole series. Nothing has been read or written.
        case choosingScope(event: EventSnapshot, rosterID: UUID)
        case previewing(event: EventSnapshot, rosterID: UUID)
        case reviewing(Review)
        case applying(Review)
    }
    private(set) var flow: Flow = .idle
    /// Background read-only locate run feeding the fast apply. Its value is
    /// the Calendar-scripting uid (nil if locate failed). Cancelling it
    /// terminates the osascript process, so an abandoned review never leaves
    /// a scan running for later requests to queue behind.
    private var locateTask: Task<String?, Never>?
    /// How long confirm waits for an unfinished locate before cancelling it
    /// and letting apply scan on its own. Waiting is usually cheaper: the
    /// locate is already part-way through the same scan apply would do.
    private static let locateWaitLimit: Duration = .seconds(30)
    /// Set when a drop found nothing to add.
    private(set) var allPresentEvent: EventSnapshot?
    /// One-shot summary of an apply attempt (success, partial, or error).
    private(set) var resultMessage: String?
    /// One-shot error outside the review flow (permissions, mismatch, crash).
    var alertMessage: String?
    /// Roster's Automation → Calendar permission, as last checked.
    private(set) var automationPermission: CalendarAutomation.AutomationPermission = .unknown

    var isBusy: Bool {
        // Preview blocks drops too: a second drop would overwrite the flow
        // state the first preview's task is about to publish into.
        if case .applying = flow { return true }
        if case .previewing = flow { return true }
        return automation.busy
    }

    var isPreviewing: Bool {
        if case .previewing = flow { return true }
        return false
    }

    var isReviewingOrApplying: Bool {
        switch flow {
        case .reviewing, .applying: return true
        default: return false
        }
    }
    /// The flow sheet covers the whole drag pipeline: preview spinner,
    /// review dialog, and the applying state.
    var showsFlowSheet: Bool {
        if case .idle = flow { return false }
        return true
    }

    init(rosterStore: RosterStore, contactsService: ContactsService, calendarService: CalendarService, automation: CalendarAutomation) {
        self.rosterStore = rosterStore
        self.contactsService = contactsService
        self.calendarService = calendarService
        self.automation = automation
    }

    /// Builds the app's store: the saved folder when one was chosen,
    /// otherwise the default Application Support library. A saved folder
    /// that cannot be read surfaces a blocking error; it never silently
    /// falls back to Application Support.
    static func makeRosterStore() -> RosterStore {
        if let path = UserDefaults.standard.string(forKey: storageDirectoryKey) {
            return RosterStore(directory: URL(fileURLWithPath: path), requireExistingFile: true)
        }
        return RosterStore()
    }

    /// Switching storage is disabled mid-drag/review so roster references
    /// held by the flow stay valid.
    var canChangeStorageDirectory: Bool {
        if case .idle = flow { return true }
        return false
    }

    /// Switches to `url`, then persists the choice. Failures leave the
    /// preference and store untouched and surface via `alertMessage`.
    @discardableResult
    func changeRosterDirectory(to url: URL) -> Bool {
        do {
            try rosterStore.switchDirectory(to: url)
            UserDefaults.standard.set(url.path, forKey: Self.storageDirectoryKey)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// Switches back to the default Application Support library, then clears
    /// the saved preference. Failures leave both untouched.
    @discardableResult
    func useDefaultRosterDirectory() -> Bool {
        do {
            try rosterStore.switchDirectory(to: RosterStore.defaultDirectory())
            UserDefaults.standard.removeObject(forKey: Self.storageDirectoryKey)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    /// Calendar first, then Automation (prompting now, during setup, rather
    /// than on the first drop), then Contacts. Automation needs Calendar
    /// running to be checked, so Calendar is launched hidden first; that also
    /// takes its cold start off the first drop.
    func requestPermissions() async {
        await calendarService.requestAccess()
        if calendarService.accessState == .authorized {
            await automation.launchCalendarIfNeeded()
            await updateAutomationPermission(ask: true)
        }
        await contactsService.requestAccess()
    }

    /// Re-checks without prompting, e.g. after returning from System
    /// Settings. An inconclusive answer (Calendar not running) keeps the
    /// last known state.
    func refreshAutomationPermission() async {
        guard calendarService.accessState == .authorized, CalendarAutomation.isCalendarRunning else { return }
        await updateAutomationPermission(ask: false)
    }

    /// Asks again from the in-app notice when the user never answered.
    func requestAutomationPermission() async {
        await automation.launchCalendarIfNeeded()
        await updateAutomationPermission(ask: true)
    }

    private func updateAutomationPermission(ask: Bool) async {
        let permission = await CalendarAutomation.automationPermission(ask: ask)
        if permission != .unknown {
            automationPermission = permission
        }
    }

    /// Records a denial seen by an automation run, so the notice appears.
    private func noteAutomationError(_ error: any Error) {
        if let error = error as? CalendarAutomationError, error == .notAuthorized {
            automationPermission = .denied
        }
    }
    /// Entry point for a drop of `rosterID` onto `event`. Drops on targets we
    /// cannot safely automate are ignored.
    func handleDrop(rosterID: UUID, event: EventSnapshot) {
        guard !isBusy else { return }
        guard event.canDrop else {
            alertMessage = "This event cannot accept invitees: it is canceled, read-only, or missing identifiers Calendar can match."
            return
        }
        guard automationPermission != .denied else {
            alertMessage = CalendarAutomationError.notAuthorized.errorDescription
            return
        }
        guard rosterStore.persistentError == nil else { return }
        guard let roster = rosterStore.rosters.first(where: { $0.id == rosterID }), !roster.members.isEmpty else {
            return
        }
        if event.isDetached {
            // Changed occurrence: the user picks the scope before any read.
            flow = .choosingScope(event: event, rosterID: rosterID)
            return
        }
        startPreview(event: event, rosterID: rosterID)
    }

    /// Continues a drop on a changed occurrence with the chosen scope.
    func chooseScope(onlyThisOccurrence: Bool) {
        guard case .choosingScope(let event, let rosterID) = flow else { return }
        startPreview(event: event, rosterID: rosterID, onlyThisOccurrence: onlyThisOccurrence)
    }

    private func startPreview(event: EventSnapshot, rosterID: UUID, onlyThisOccurrence: Bool = false) {
        guard let roster = rosterStore.rosters.first(where: { $0.id == rosterID }) else {
            alertMessage = "That roster no longer exists."
            flow = .idle
            return
        }
        cancelLocate()
        flow = .previewing(event: event, rosterID: rosterID)
        Task {
            do {
                // Fast path: read attendees in-process via EventKit. The drop
                // already carries the exact event, so nothing needs to be
                // re-matched inside Calendar.app. nil means unknown attendee
                // state (event gone, or no attendee list) — fail closed to
                // the osascript preview.
                let review: Review
                if let emails = calendarService.attendeeEmails(for: event, onlyThisOccurrence: onlyThisOccurrence) {
                    review = Review(
                        event: event,
                        rosterID: rosterID,
                        required: roster.members,
                        missingKeys: missingKeys(
                            required: roster.members.map(\.email),
                            attendeeEmails: emails
                        ),
                        isSeries: onlyThisOccurrence ? false : event.isSeries,
                        locatedUID: nil,
                        onlyThisOccurrence: onlyThisOccurrence
                    )
                } else {
                    review = try await automation.preview(event: event, roster: roster, onlyThisOccurrence: onlyThisOccurrence)
                }
                if review.missingKeys.isEmpty {
                    allPresentEvent = event
                    flow = .idle
                } else {
                    flow = .reviewing(review)
                    // While the user reviews, resolve the event's
                    // Calendar-scripting uid once (read-only). That scan is
                    // the slow part of apply; overlapping it with the review
                    // lets confirm write through byId in seconds. A stale or
                    // failed locate is harmless: apply verifies the uid and
                    // falls back to its own scan.
                    // Not for a single changed occurrence: locate resolves the
                    // series, and that apply addresses the occurrence by its
                    // own id (already instant) and must never use a series uid.
                    if !onlyThisOccurrence {
                        let automation = automation
                        locateTask = Task {
                            (try? await automation.locate(event: event)) ?? nil
                        }
                    }
                }
            } catch {
                noteAutomationError(error)
                flow = .idle
                alertMessage = error.localizedDescription
            }
        }
    }

    func cancelReview() {
        // No write ever happens on cancel or dismissal.
        if case .applying = flow { return } // Never cancel mid-apply.
        if case .previewing = flow { return } // Preview is read-only; it publishes its own result.
        cancelLocate()
        flow = .idle
    }

    private func cancelLocate() {
        locateTask?.cancel()
        locateTask = nil
    }

    /// The located uid for `review`: already known, or the in-flight locate's
    /// result. Waits at most `locateWaitLimit`; past that the locate is
    /// cancelled (terminating its process) so apply never runs concurrently
    /// with it inside Calendar.app.
    private func locatedUID(for review: Review) async -> String? {
        if let uid = review.locatedUID { return uid }
        guard let task = locateTask else { return nil }
        enum Outcome: Sendable { case located(String?), timedOut }
        let limit = Self.locateWaitLimit
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .located(await task.value) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            if case .timedOut = first { task.cancel() }
            group.cancelAll()
            return first
        }
        if case .located(let uid) = outcome { return uid }
        return nil
    }

    func confirmReview() {
        guard case .reviewing(let review) = flow else { return }
        guard let roster = rosterStore.rosters.first(where: { $0.id == review.rosterID }) else {
            cancelLocate()
            flow = .idle
            alertMessage = "That roster was deleted; nothing was added."
            return
        }
        if roster.members != review.required {
            // Edited since preview: close the stale review and preview again.
            startPreview(event: review.event, rosterID: roster.id, onlyThisOccurrence: review.onlyThisOccurrence)
            return
        }
        flow = .applying(review)
        Task {
            do {
                var review = review
                if let uid = await locatedUID(for: review) {
                    review = review.withLocatedUID(uid)
                }
                let event = review.event
                let onlyThisOccurrence = review.onlyThisOccurrence
                let calendarService = calendarService
                let result = try await automation.apply(review: review) {
                    calendarService.attendeeEmails(for: event, onlyThisOccurrence: onlyThisOccurrence)
                }
                switch result {
                case .changed(let fresh):
                    flow = .reviewing(fresh)
                    alertMessage = "The event changed since the last review. Please review the missing invitees again."
                case .finished(let added, let remaining, let warning):
                    cancelLocate()
                    flow = .idle
                    resultMessage = Self.describe(added: added, remaining: remaining, warning: warning)
                    await calendarService.refresh()
                }
            } catch {
                noteAutomationError(error)
                cancelLocate()
                flow = .idle
                alertMessage = error.localizedDescription
            }
        }
    }

    nonisolated private static func describe(added: [String], remaining: [String], warning: String?) -> String {
        var lines: [String] = []
        if added.isEmpty {
            lines.append("No addresses were added.")
        } else {
            lines.append("Added: " + added.joined(separator: ", "))
        }
        if !remaining.isEmpty {
            lines.append("Still missing: " + remaining.joined(separator: ", "))
        }
        if let warning { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    func dismissAllPresent() {
        allPresentEvent = nil
    }

    func dismissResult() {
        resultMessage = nil
    }

    func dismissAlert() {
        alertMessage = nil
    }
}
