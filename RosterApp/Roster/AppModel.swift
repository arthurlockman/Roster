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
        case previewing(event: EventSnapshot, rosterID: UUID)
        case reviewing(Review)
        case applying(Review)
    }
    private(set) var flow: Flow = .idle
    /// Background read-only locate run feeding the fast apply; the result is
    /// dropped unless the same review is still on screen.
    private var locateTask: Task<Void, Never>?
    /// Set when a drop found nothing to add.
    private(set) var allPresentEvent: EventSnapshot?
    /// One-shot summary of an apply attempt (success, partial, or error).
    private(set) var resultMessage: String?
    /// One-shot error outside the review flow (permissions, mismatch, crash).
    var alertMessage: String?

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

    func requestPermissions() async {
        await calendarService.requestAccess()
        await contactsService.requestAccess()
    }
    /// Entry point for a drop of `rosterID` onto `event`. Drops on targets we
    /// cannot safely automate are ignored.
    func handleDrop(rosterID: UUID, event: EventSnapshot) {
        guard !isBusy else { return }
        guard event.canDrop else {
            alertMessage = "This event cannot accept invitees: it is canceled, read-only, or missing identifiers Calendar can match."
            return
        }
        guard rosterStore.persistentError == nil else { return }
        guard let roster = rosterStore.rosters.first(where: { $0.id == rosterID }), !roster.members.isEmpty else {
            return
        }
        startPreview(event: event, rosterID: rosterID)
    }

    private func startPreview(event: EventSnapshot, rosterID: UUID) {
        guard let roster = rosterStore.rosters.first(where: { $0.id == rosterID }) else {
            alertMessage = "That roster no longer exists."
            flow = .idle
            return
        }
        flow = .previewing(event: event, rosterID: rosterID)
        Task {
            do {
                // Fast path: read attendees in-process via EventKit. The drop
                // already carries the exact event, so nothing needs to be
                // re-matched inside Calendar.app. nil means unknown attendee
                // state (event gone, or no attendee list) — fail closed to
                // the osascript preview.
                let review: Review
                if let emails = calendarService.attendeeEmails(forEventIdentifier: event.eventIdentifier) {
                    review = Review(
                        event: event,
                        rosterID: rosterID,
                        required: roster.members,
                        missingKeys: missingKeys(
                            required: roster.members.map(\.email),
                            attendeeEmails: emails
                        ),
                        isSeries: event.isSeries,
                        locatedUID: nil
                    )
                } else {
                    review = try await automation.preview(event: event, roster: roster)
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
                    locateTask = Task {
                        guard let uid = try? await automation.locate(event: event) else { return }
                        if case .reviewing(let current) = flow,
                           current.rosterID == rosterID, current.event == event, current.locatedUID == nil {
                            flow = .reviewing(current.withLocatedUID(uid))
                        }
                    }
                }
            } catch {
                flow = .idle
                alertMessage = error.localizedDescription
            }
        }
    }

    func cancelReview() {
        // No write ever happens on cancel or dismissal.
        if case .applying = flow { return } // Never cancel mid-apply.
        if case .previewing = flow { return } // Preview is read-only; it publishes its own result.
        flow = .idle
    }

    func confirmReview() {
        guard case .reviewing(let review) = flow else { return }
        guard let roster = rosterStore.rosters.first(where: { $0.id == review.rosterID }) else {
            flow = .idle
            alertMessage = "That roster was deleted; nothing was added."
            return
        }
        if roster.members != review.required {
            // Edited since preview: close the stale review and preview again.
            startPreview(event: review.event, rosterID: roster.id)
            return
        }
        flow = .applying(review)
        Task {
            do {
                let result = try await automation.apply(review: review)
                switch result {
                case .changed(let fresh):
                    flow = .reviewing(fresh)
                    alertMessage = "The event changed since the last review. Please review the missing invitees again."
                case .finished(let added, let remaining, let warning):
                    flow = .idle
                    resultMessage = Self.describe(added: added, remaining: remaining, warning: warning)
                    await calendarService.refresh()
                }
            } catch {
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
