import EventKit
import Observation
import SwiftUI

/// Immutable data copied out of an `EKEvent`. EventKit objects are invalidated
/// when the store changes, so everything the UI and the automation bridge need
/// travels in this value. IDs must be nonempty; a snapshot with missing IDs
/// cannot be drop-target-matched later and is treated as non-droppable.
nonisolated struct EventSnapshot: Identifiable, Hashable, Sendable {
    let eventIdentifier: String
    let calendarItemExternalIdentifier: String
    let calendarIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let isDetached: Bool
    let hasRecurrenceRules: Bool
    let occurrenceDate: Date?
    let isCanceled: Bool
    let calendarIsWritable: Bool
    let calendarTitle: String
    /// The calendar's own color as configured in Calendar.app.
    let calendarColor: Color?

    var id: String { eventIdentifier }
    /// True when the snapshot is a single occurrence of a recurring series
    /// rather than the master itself: EventKit occurrenceDate differs from the
    /// occurrence's own startDate only for occurrences.
    var isOccurrence: Bool {
        guard let occurrenceDate else { return false }
        return occurrenceDate != startDate
    }
    /// Whole-series scope: recurrence on the master, a detached exception, or
    /// a plain occurrence. Drives the "Add to recurring series" warning.
    var isSeries: Bool { hasRecurrenceRules || isDetached || isOccurrence }
    /// The automation needs the calendar title and a stable EventKit id.
    /// calendarIdentifier and calendarItemExternalIdentifier are passed as
    /// exact-lookup hints (Calendar's scripting resolves both on iCloud) but
    /// are not required: the script falls back to conservative matching.
    var canDrop: Bool {
        !eventIdentifier.isEmpty
            && !calendarTitle.isEmpty
            && calendarIsWritable
            && !isCanceled
    }
}

/// Reads events through EventKit. Writes never go through EventKit — attendee
/// additions run through Calendar.app automation only.
@Observable
final class CalendarService {
    enum AccessState: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    private(set) var accessState: AccessState = .notDetermined
    private(set) var calendars: [EKCalendar] = []
    private(set) var selectedCalendarIDs: Set<String> = []
    private(set) var events: [EventSnapshot] = []
    private(set) var fetchError: String?
    private(set) var day: Date = Calendar.current.startOfDay(for: .now)

    /// Base store: authorization and source discovery. Its `sources` exclude
    /// delegate sources.
    private let baseStore = EKEventStore()
    /// Store scoped to ordinary + delegate sources; rebuilt whenever the set
    /// of delegate sources changes. Apple's documented path for delegated
    /// calendars (EKEventStore.delegateSources + init(sources:)).
    private var scopedStore: EKEventStore?
    private var scopedSourceIDs: Set<String> = []
    private var observers: [any NSObjectProtocol] = []
    /// Pending coalesced refetch; see `scheduleRefetch`.
    private var refetchTask: Task<Void, Never>?

    private var activeStore: EKEventStore { scopedStore ?? baseStore }

    private static let selectionKey = "selectedCalendarIdentifiers"

    init() {
        selectedCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: Self.selectionKey) ?? [])
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: .main
            ) { [weak self] _ in
                // Documented EventKit rule: cached EKEvent objects are
                // invalidated by store changes; refetch everything.
                self?.scheduleRefetch()
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("NSApplicationDidBecomeActiveNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.scheduleRefetch()
            }
        )
    }

    /// Store changes arrive in bursts (an account sync or an automation
    /// write can post dozens), and each refetch is a
    /// synchronous EventKit query on the main actor. Coalesce them into one
    /// refetch after the burst settles.
    private func scheduleRefetch() {
        refetchTask?.cancel()
        refetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refetchCalendarsAndEvents()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func requestAccess() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            accessState = .authorized
        case .notDetermined:
            do {
                let granted = try await baseStore.requestFullAccessToEvents()
                accessState = granted ? .authorized : .denied
            } catch {
                accessState = .denied
                fetchError = error.localizedDescription
            }
        case .denied, .restricted:
            accessState = .denied
        default:
            accessState = .denied
        }
        if accessState == .authorized {
            await refetchCalendarsAndEvents()
        }
    }

    var selectedCalendars: [EKCalendar] {
        calendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
    }

    /// Explicit selection; first authorization selects every calendar.
    func setSelected(_ id: String, selected: Bool) {
        var ids = selectedCalendarIDs
        if selected { ids.insert(id) } else { ids.remove(id) }
        selectedCalendarIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.selectionKey)
        Task { await refetchEvents() }
    }
    /// Refetches calendars and events (e.g. after an automation write).
    func refresh() async {
        await refetchCalendarsAndEvents()
    }

    func goToDay(_ newDay: Date) {
        day = Calendar.current.startOfDay(for: newDay)
        Task { await refetchEvents() }
    }

    func goToPreviousDay() { shiftDay(-1) }
    func goToNextDay() { shiftDay(1) }
    func goToToday() { goToDay(.now) }

    private func shiftDay(_ delta: Int) {
        let current = Calendar.current.date(byAdding: .day, value: delta, to: day) ?? day
        goToDay(current)
    }

    private func refetchCalendarsAndEvents() async {
        guard accessState == .authorized else { return }
        // Apple's documented path for delegated calendars: the default store
        // excludes delegate sources, so a second store scoped to ordinary +
        // delegate sources exposes them (EKEventStore.delegateSources).
        // Rebuild when the delegate set changes.
        let delegateIDs = Set(baseStore.delegateSources.map(\.sourceIdentifier))
        if scopedStore == nil || delegateIDs != scopedSourceIDs {
            scopedStore = EKEventStore(sources: baseStore.sources + baseStore.delegateSources)
            scopedSourceIDs = delegateIDs
        }
        calendars = activeStore.calendars(for: .event)
        // First run: show everything, so the day list is never mysteriously
        // empty. Afterwards the user's explicit selection wins; a calendar
        // added later is not auto-selected.
        if UserDefaults.standard.object(forKey: Self.selectionKey) == nil {
            selectedCalendarIDs = Set(calendars.map(\.calendarIdentifier))
            UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: Self.selectionKey)
        }
        // Drop selections whose calendar vanished.
        let validIDs = Set(calendars.map(\.calendarIdentifier))
        if !validIDs.isSuperset(of: selectedCalendarIDs) {
            selectedCalendarIDs.formIntersection(validIDs)
            UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: Self.selectionKey)
        }
        await refetchEvents()
    }

    private func refetchEvents() async {
        guard accessState == .authorized else { return }
        let targets = selectedCalendars
        guard !targets.isEmpty else {
            events = []
            fetchError = nil
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        // Next calendar day, never a fixed 86,400-second window (DST-safe).
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = activeStore.predicateForEvents(withStart: start, end: end, calendars: targets)
        let matches = activeStore.events(matching: predicate)
        let snapshots = matches.map { Self.snapshot(of: $0) }
        events = snapshots.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            return a.title < b.title
        }
        fetchError = nil
    }

    nonisolated static func snapshot(of event: EKEvent) -> EventSnapshot {
        EventSnapshot(
            eventIdentifier: event.eventIdentifier ?? "",
            calendarItemExternalIdentifier: event.calendarItemExternalIdentifier ?? "",
            calendarIdentifier: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            isDetached: event.isDetached,
            hasRecurrenceRules: !(event.recurrenceRules?.isEmpty ?? true),
            occurrenceDate: event.occurrenceDate,
            isCanceled: event.status == .canceled,
            calendarIsWritable: event.calendar?.allowsContentModifications ?? false,
            calendarTitle: event.calendar?.title ?? "",
            calendarColor: event.calendar?.color.map { Color(nsColor: $0) }
        )
    }

    /// Attendee email addresses of the invitee list Roster would write to,
    /// read in-process via EventKit: the event itself, or for a recurring
    /// event the series. Returns nil when that list is unknown or isn't the
    /// one in hand — an unknown list must never look like an empty one, so
    /// callers fail closed to the osascript preview, which reads exactly
    /// what apply writes to.
    ///
    /// - A detached (individually edited) occurrence can carry its own
    ///   invitees, but Roster writes to the series, so this returns nil and
    ///   the script reads the series.
    /// - For other occurrences the dropped occurrence is re-fetched; its
    ///   invitees are the series'. `event(withIdentifier:)` would return the
    ///   series' first occurrence, which may itself be detached.
    /// - EventKit materializes participant data lazily: an event Calendar.app
    ///   already shows with invitees can briefly read as `attendees == nil`
    ///   with `hasAttendees == false`. Neither is trusted — an empty claim
    ///   fails closed to the osascript preview, which reads exactly what
    ///   apply writes to. A non-empty list proves the data loaded and is
    ///   taken at face value.
    ///
    /// EKParticipant exposes its address only as a mailto: URL; keys are
    /// normalized exactly like the script normalizes emails.
    ///
    /// With `onlyThisOccurrence` the target is the changed occurrence itself,
    /// so its own invitee list is the right one to read.
    func attendeeEmails(for snapshot: EventSnapshot, onlyThisOccurrence: Bool = false) -> [String]? {
        guard accessState == .authorized, !snapshot.eventIdentifier.isEmpty else { return nil }
        guard snapshot.isDetached == onlyThisOccurrence else { return nil }
        guard let event = currentEvent(for: snapshot), event.isDetached == onlyThisOccurrence else { return nil }
        guard let attendees = event.attendees else { return nil }
        let keys = attendees.compactMap { normalizedEmailKey($0.url.absoluteString) }
        return keys.isEmpty ? nil : keys
    }

    /// The live EKEvent for a snapshot: by identifier for a one-off event,
    /// or the exact occurrence (same identifier and start) for a series.
    private func currentEvent(for snapshot: EventSnapshot) -> EKEvent? {
        guard snapshot.isSeries else {
            return activeStore.event(withIdentifier: snapshot.eventIdentifier)
        }
        guard let calendar = activeStore.calendar(withIdentifier: snapshot.calendarIdentifier) else { return nil }
        let end = max(snapshot.endDate, snapshot.startDate.addingTimeInterval(1))
        let predicate = activeStore.predicateForEvents(withStart: snapshot.startDate, end: end, calendars: [calendar])
        let matches = activeStore.events(matching: predicate).filter {
            $0.eventIdentifier == snapshot.eventIdentifier && $0.startDate == snapshot.startDate
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
