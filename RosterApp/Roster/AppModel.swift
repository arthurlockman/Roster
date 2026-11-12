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

    enum Flow {
        case idle
        case previewing(event: EventSnapshot, rosterID: UUID)
        case reviewing(Review)
        case applying(Review)
    }
    private(set) var flow: Flow = .idle
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
                let review = try await automation.preview(event: event, roster: roster)
                if review.missingKeys.isEmpty {
                    allPresentEvent = event
                    flow = .idle
                } else {
                    flow = .reviewing(review)
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
