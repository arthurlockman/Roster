import AppKit
import EventKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var pickerTarget: PickerTarget?
    @State private var showingOnboarding = false

    /// Set after the first-run walkthrough finishes or is skipped.
    static let onboardingSeenKey = "hasSeenOnboarding"

    var body: some View {
        HSplitView {
            dayListPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            rosterPane
                .frame(minWidth: 320, maxWidth: 520, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            // First-run walkthrough goes first; macOS permission prompts
            // would otherwise land on top of the instructions.
            if UserDefaults.standard.bool(forKey: Self.onboardingSeenKey) {
                await model.requestPermissions()
            }
        }
        .task {
            if !UserDefaults.standard.bool(forKey: Self.onboardingSeenKey) {
                showingOnboarding = true
            }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingSheet {
                UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
                showingOnboarding = false
                Task { await model.requestPermissions() }
            }
        }
        .sheet(isPresented: BindableSheet(model, keyPath: \.showsFlowSheet)) {
            switch model.flow {
            case .previewing(let event, _):
                PreviewSheet(event: event)
            case .reviewing(let review):
                ReviewSheet(model: model, review: review, isApplying: false)
            case .applying(let review):
                ReviewSheet(model: model, review: review, isApplying: true)
            default:
                EmptyView()
            }
        }
        .interactiveDismissDisabled(model.isPreviewing)
        .sheet(isPresented: Binding(
            get: { model.resultMessage != nil },
            set: { if !$0 { model.dismissResult() } }
        )) {
            ResultSheet(model: model)
        }
        .sheet(item: $pickerTarget) { target in
            ContactPickerSheet(model: model, rosterID: target.rosterID)
        }
        .alert("Nothing to add", isPresented: Binding(
            get: { model.allPresentEvent != nil },
            set: { if !$0 { model.dismissAllPresent() } }
        )) {
            Button("OK") { model.dismissAllPresent() }
        } message: {
            Text("All invitees are already present")
        }
        .alert(item: Binding(
            get: { model.alertMessage.map(GenericAlert.init) },
            set: { if $0 == nil { model.dismissAlert() } }
        )) { alert in
            Alert(title: Text("Roster"), message: Text(alert.text))
        }
    }

    // MARK: - Left: day list

    private var dayListPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.calendarService.goToPreviousDay() } label: { Image(systemName: "chevron.left") }
                Button("Today") { model.calendarService.goToToday() }
                Button { model.calendarService.goToNextDay() } label: { Image(systemName: "chevron.right") }
                Spacer()
                Text(model.calendarService.day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.headline)
                Spacer()
                CalendarFilterMenu(calendarService: model.calendarService)
            }
            .padding(.horizontal)

            if model.calendarService.accessState == .denied {
                deniedCalendarNotice
            } else if let fetchError = model.calendarService.fetchError {
                Text(fetchError).foregroundStyle(.red).padding()
            } else if model.calendarService.selectedCalendarIDs.isEmpty {
                ContentUnavailableView(
                    "No calendars selected",
                    systemImage: "calendar",
                    description: Text("Use the Calendars menu to pick which calendars to show.")
                )
            } else if model.calendarService.events.isEmpty {
                ContentUnavailableView("No events", systemImage: "calendar.badge.clock")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.calendarService.events) { event in
                            EventRow(event: event, model: model)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical)
    }

    private var deniedCalendarNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access was denied.").font(.headline)
            Text("Roster shows this day as unavailable rather than pretending it is empty. Grant access in System Settings → Privacy & Security → Calendars.")
            Button("Open System Settings") { Self.openPrivacySettings() }
        }
        .padding()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllCalendarData") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Right: rosters

    private var rosterPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rosters").font(.headline)
                Spacer()
                if let persistentError = model.rosterStore.persistentError {
                    Button("Data error") { model.alertMessage = persistentError.errorDescription }
                        .foregroundStyle(.red)
                }
                Button {
                    showingOnboarding = true
                } label: {
                    Label("How to use", systemImage: "questionmark.circle")
                }
                .help("Show the walkthrough again")
                Button {
                    do { _ = try model.rosterStore.createRoster(named: "New roster") }
                    catch { model.alertMessage = error.localizedDescription }
                } label: {
                    Label("New Roster", systemImage: "plus")
                }
            }
            .padding(.horizontal)

            if model.contactsService.accessState == .denied {
                deniedContactsNotice
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rosterStore.rosters) { roster in
                        VStack(spacing: 0) {
                            RosterDropGap(model: model, insertBeforeID: roster.id)
                            RosterCard(model: model, roster: roster) {
                                pickerTarget = PickerTarget(rosterID: roster.id)
                            }
                        }
                    }
                    RosterDropGap(model: model, insertBeforeID: nil)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical)
    }

    private var deniedContactsNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Contacts access denied", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text("Saved rosters stay visible and editable here. To pick from contacts, grant access in System Settings → Privacy & Security → Contacts.")
            Button("Open System Settings") { Self.openPrivacySettings() }
        }
        .padding(.horizontal)
    }
}

/// Turns an optional string into Identifiable for `.alert(item:)`.
private struct GenericAlert: Identifiable {
    let id = UUID()
    let text: String
}

/// Sheet presentation target for the contact picker.
private struct PickerTarget: Identifiable {
    let rosterID: UUID
    var id: UUID { rosterID }
}

/// Sheet presentation binding over an Observable key path.
private func BindableSheet(_ model: AppModel, keyPath: KeyPath<AppModel, Bool>) -> Binding<Bool> {
    Binding(
        get: { model[keyPath: keyPath] },
        set: { shown in
            if !shown { model.cancelReview() }
        }
    )
}

// MARK: - Event row (drop target)

private struct EventRow: View {
    let event: EventSnapshot
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor ?? Color.accentColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title.isEmpty ? "(untitled)" : event.title)
                        .font(.body.weight(.medium))
                    if event.isSeries {
                        Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                    }
                    if event.isCanceled {
                        Text("Canceled").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                }
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(event.canDrop ? 1 : 0.45)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard items.count == 1, let id = items.first.flatMap(UUID.init(uuidString:)),
                  !id.uuidString.isEmpty else { return false }
            model.handleDrop(rosterID: id, event: event)
            return true
        } isTargeted: { targeted in
            _ = targeted
        }
        .help(event.canDrop ? "Drop a roster here to add missing invitees" : "This event cannot accept invitees")
    }

    private var timeText: String {
        if event.isAllDay { return String(localized: "all-day") }
        return event.startDate.formatted(date: .omitted, time: .shortened)
            + " – "
            + event.endDate.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Calendar filter menu

private struct CalendarFilterMenu: View {
    let calendarService: CalendarService

    var body: some View {
        Menu {
            if calendarService.calendars.isEmpty {
                Text("No calendars found")
            }
            ForEach(calendarService.calendars, id: \.calendarIdentifier) { calendar in
                Toggle(calendar.title, isOn: Binding(
                    get: { calendarService.selectedCalendarIDs.contains(calendar.calendarIdentifier) },
                    set: { calendarService.setSelected(calendar.calendarIdentifier, selected: $0) }
                ))
            }
        } label: {
            Label("Calendars", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

// MARK: - Roster card (drag source)

private struct RosterCard: View {
    let model: AppModel
    let roster: Roster
    let pickContact: () -> Void

    @State private var isExpanded = true
    @State private var renaming = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let emoji = roster.emoji, !emoji.isEmpty {
                    Text(emoji).font(.title3)
                } else {
                    Image(systemName: "person.3")
                }
                Text(roster.name).font(.headline)
                    .foregroundStyle(mainText)
                Spacer()
                Menu {
                    Button("Add contact…", action: pickContact)
                    Button("Rename…") { renameDraft = roster.name; renaming = true }
                    Button("Customize Appearance…") { editingAppearance = true }
                    Divider()
                    Button("Move Up") { moveBy(-1) }
                        .disabled(model.rosterStore.rosters.first?.id == roster.id)
                    Button("Move Down") { moveBy(1) }
                        .disabled(model.rosterStore.rosters.last?.id == roster.id)
                    Button("Delete", role: .destructive) {
                        do { try model.rosterStore.deleteRoster(roster.id) }
                        catch { model.alertMessage = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if isExpanded {
                ForEach(roster.members) { member in
                    HStack {
                        Text(member.displayName.isEmpty ? member.email : member.displayName)
                            .foregroundStyle(mainText)
                        Text(member.email).foregroundStyle(secondaryText).font(.caption)
                        Spacer()
                        Button {
                            try? model.rosterStore.removeMember(from: roster.id, memberID: member.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if roster.members.isEmpty {
                    Text("Empty — add contacts, then drag this card onto an event.")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                } else {
                    Text("Drag this roster onto an event.")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardFill))
        .draggable(roster.id.uuidString) {
            // Compact lift-off preview: the whole card would ghost a
            // full-width duplicate over the list while dragging.
            HStack(spacing: 6) {
                if let emoji = roster.emoji, !emoji.isEmpty {
                    Text(emoji)
                } else {
                    Image(systemName: "person.3")
                }
                Text(roster.name).font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(.thickMaterial))
        }
        .onTapGesture { isExpanded.toggle() }
        .alert("Rename roster", isPresented: $renaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                do { try model.rosterStore.renameRoster(roster.id, to: renameDraft) }
                catch { model.alertMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editingAppearance) {
            AppearanceSheet(model: model, roster: roster)
        }
    }

    @State private var editingAppearance = false

    /// Nil when the card uses the system background; otherwise the custom
    /// color and a contrasting text color picked from its luminance.
    private var cardFill: AnyShapeStyle {
        if let hex = roster.backgroundColorHex, let color = RosterAppearance.color(fromHex: hex) {
            return AnyShapeStyle(color)
        }
        return AnyShapeStyle(.background.secondary)
    }

    private var mainText: Color {
        guard let hex = roster.backgroundColorHex else { return Color(nsColor: .labelColor) }
        return RosterAppearance.isLight(hex) ? Color(white: 0.1) : .white
    }

    private var secondaryText: Color {
        guard let hex = roster.backgroundColorHex else { return Color(nsColor: .secondaryLabelColor) }
        return RosterAppearance.isLight(hex) ? Color(white: 0.1).opacity(0.7) : Color.white.opacity(0.75)
    }

    /// Fallback for drag reordering: shifts the card one position.
    private func moveBy(_ delta: Int) {
        guard let index = model.rosterStore.rosters.firstIndex(where: { $0.id == roster.id }) else { return }
        let count = model.rosterStore.rosters.count
        let target = index + delta + (delta > 0 ? 1 : 0)
        guard (0...count).contains(target), target != index, target != index + 1 else { return }
        try? model.rosterStore.moveRosters(fromOffsets: IndexSet(integer: index), toOffset: target)
    }
}

/// The insertion point between two roster cards (and after the last one).
/// `insertBeforeID` is the card below the gap, or nil for the end-of-list
/// gap. Dropping a roster card's drag payload here moves it to that gap.
private struct RosterDropGap: View {
    let model: AppModel
    let insertBeforeID: UUID?

    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(hovering ? 1 : 0))
                .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let draggedID = UUID(uuidString: raw),
                  let fromIndex = model.rosterStore.rosters.firstIndex(where: { $0.id == draggedID })
            else { return false }
            let toOffset: Int
            if let insertBeforeID {
                guard insertBeforeID != draggedID,
                      let toIndex = model.rosterStore.rosters.firstIndex(where: { $0.id == insertBeforeID })
                else { return false }
                toOffset = toIndex
            } else {
                toOffset = model.rosterStore.rosters.count
            }
            // Already at that position: not a handled drop.
            guard toOffset != fromIndex, toOffset != fromIndex + 1 else { return false }
            do {
                try model.rosterStore.moveRosters(fromOffsets: IndexSet(integer: fromIndex), toOffset: toOffset)
                return true
            } catch {
                model.alertMessage = error.localizedDescription
                return false
            }
        } isTargeted: { hovering in
            self.hovering = hovering
        }
        .animation(.easeInOut(duration: 0.1), value: hovering)
    }
}

/// Edits a roster card's emoji icon and background color. The emoji field
/// accepts any pasted glyph; Ctrl+Cmd+Space opens the system emoji picker
/// inside it.
private struct AppearanceSheet: View {
    let model: AppModel
    let roster: Roster

    @State private var emojiDraft: String
    @State private var useColor: Bool
    @State private var color: Color
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, roster: Roster) {
        self.model = model
        self.roster = roster
        _emojiDraft = State(initialValue: roster.emoji ?? "")
        _useColor = State(initialValue: roster.backgroundColorHex != nil)
        _color = State(initialValue: roster.backgroundColorHex.flatMap { RosterAppearance.color(fromHex: $0) }
            ?? Color(nsColor: .controlAccentColor))
    }

    private var previewEmoji: String {
        emojiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "👥" : emojiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewFill: AnyShapeStyle {
        useColor ? AnyShapeStyle(color) : AnyShapeStyle(.background.secondary)
    }

    private var previewText: Color {
        guard useColor else { return Color(nsColor: .labelColor) }
        return RosterAppearance.isLight(RosterAppearance.hex(from: color)) ? Color(white: 0.1) : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Card Appearance").font(.title2.bold())
            HStack(spacing: 8) {
                TextField("Emoji", text: $emojiDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .help("Type or paste an emoji — press ⌃⌘Space for the emoji picker")
                Text(previewEmoji).font(.title3)
            }
            HStack {
                Toggle("Custom background", isOn: $useColor)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .disabled(!useColor)
            }
            HStack {
                Text(previewEmoji).font(.title3)
                Text(roster.name).font(.headline).foregroundStyle(previewText)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(previewFill))
            HStack {
                Button("Reset") {
                    try? model.rosterStore.setAppearance(rosterID: roster.id, emoji: nil, backgroundColorHex: nil)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    do {
                        try model.rosterStore.setAppearance(
                            rosterID: roster.id,
                            emoji: emojiDraft.isEmpty ? nil : emojiDraft,
                            backgroundColorHex: useColor ? RosterAppearance.hex(from: color) : nil
                        )
                    } catch {
                        model.alertMessage = error.localizedDescription
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Hex-string color helpers shared by the card and its editor. The roster
/// store normalizes colors to "#RRGGBB", so the reader can be strict.
private enum RosterAppearance {
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    static func color(fromHex hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
    }

    /// WCAG relative luminance with a generous threshold: dark text on
    /// light backgrounds, white text on anything else.
    static func isLight(_ hex: String) -> Bool {
        guard let color = color(fromHex: hex) else { return true }
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        let luminance = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return luminance > 0.6
    }
}

/// Shown while the read-only preview subprocess talks to Calendar.app —
/// replaces the previous silent gap between drop and review dialog.
private struct PreviewSheet: View {
    let event: EventSnapshot

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Talking to Calendar…")
                .font(.headline)
            Text(event.title.isEmpty ? "(untitled)" : event.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 320)
    }
}

// MARK: - Review sheet

private struct ReviewSheet: View {
    let model: AppModel
    let review: Review
    let isApplying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add missing invitees?").font(.title2.bold())
            Text(review.event.title.isEmpty ? "(untitled)" : review.event.title)
                .font(.headline)
            Text(review.event.startDate, format: .dateTime.weekday().day().month().year().hour().minute())
                .foregroundStyle(.secondary)

            if review.isSeries {
                Label("Add to recurring series (edited occurrences may differ)", systemImage: "repeat")
                    .foregroundStyle(.orange)
            }

            Text("Missing invitees").font(.subheadline.weight(.semibold))
            ForEach(review.missingInvitees) { invitee in
                HStack {
                    Text(invitee.displayName.isEmpty ? invitee.email : invitee.displayName)
                    Text(invitee.email).foregroundStyle(.secondary).font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelReview() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                Button("Add missing invitees") { model.confirmReview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying)
            }
            if isApplying {
                ProgressView("Talking to Calendar…")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Result sheet

private struct ResultSheet: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar update").font(.title2.bold())
            Text(model.resultMessage ?? "")
            HStack {
                Spacer()
                Button("OK") { model.dismissResult() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Contact picker

private struct ContactPickerSheet: View {
    let model: AppModel
    let rosterID: UUID
    @State private var searchText = ""
    @State private var manualName = ""
    @State private var manualEmail = ""
    @State private var showingPaste = false

    private var contacts: ContactsService { model.contactsService }

    private var filtered: [ContactSummary] {
        guard !searchText.isEmpty else { return contacts.summaries }
        return contacts.summaries.filter { summary in
            summary.displayName.localizedCaseInsensitiveContains(searchText)
                || summary.emailAddresses.contains { $0.value.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search name or email", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showingPaste = true
                } label: {
                    Label("Paste list…", systemImage: "doc.on.clipboard")
                }
                .help("Add a pasted list of email addresses")
                Button("Done") { dismissSheet() }
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                TextField("Name (optional)", text: $manualName)
                    .textFieldStyle(.roundedBorder)
                TextField("you@example.com", text: $manualEmail)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualEmail)
                Button("Add Email") { addManualEmail() }
                    .disabled(!manualEmailIsValid || model.rosterStore.persistentError != nil)
                    .help("Add an address that isn't a saved contact")
            }
            .padding(.horizontal)

            switch contacts.accessState {
            case .notDetermined:
                ProgressView("Requesting Contacts access…")
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Contacts access was denied.").font(.headline)
                    Text("Saved rosters remain visible and editable in the roster list. To pick from contacts, grant access in System Settings → Privacy & Security → Contacts.")
                    Button("Open System Settings") { ContentView.openPrivacySettings() }
                }
                .padding(.horizontal)
                Spacer()
            case .authorized:
                if let loadError = contacts.loadError {
                    Text(loadError).foregroundStyle(.red).padding(.horizontal)
                }
                directoryHint
                List(filtered) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.displayName).font(.body.weight(.medium))
                        if summary.emailAddresses.isEmpty {
                            Text("No email address").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(summary.emailAddresses) { email in
                            HStack {
                                Text(email.label).font(.caption).foregroundStyle(.secondary)
                                Text(email.value)
                                Spacer()
                                Button("Add") { add(summary: summary, email: email.value) }
                                    .disabled(model.rosterStore.persistentError != nil)
                            }
                        }
                    }
                }
            }

            if let roster = model.rosterStore.rosters.first(where: { $0.id == rosterID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In “\(roster.name)”").font(.subheadline.weight(.semibold))
                    ForEach(roster.members) { member in
                        HStack {
                            Text(member.displayName.isEmpty ? member.email : member.displayName)
                            Text(member.email).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Button {
                                try? model.rosterStore.removeMember(from: rosterID, memberID: member.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical)
        .frame(width: 520, height: 560)
        .task {
            if contacts.accessState == .notDetermined {
                await contacts.requestAccess()
            } else if contacts.accessState == .authorized {
                await contacts.refresh()
            }
        }
        .sheet(isPresented: $showingPaste) {
            PasteSheet(model: model, rosterID: rosterID)
        }
    }

    private var directoryHint: some View {
        Text("Looking for a company/directory contact? Roster can only read saved contacts. In Contacts.app, search the connected directory, then drag the result into any non-directory list; it appears here after the refresh.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    @Environment(\.dismiss) private var dismissSheet

    private func add(summary: ContactSummary, email: String) {
        do {
            try model.rosterStore.addMember(
                to: rosterID,
                displayName: summary.displayName,
                email: email,
                contactIdentifier: summary.id
            )
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    /// Loose shape check only — a real deliverability test happens when
    /// Calendar.app tries to create the attendee.
    private var manualEmailIsValid: Bool {
        let trimmed = manualEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    private func addManualEmail() {
        guard manualEmailIsValid else { return }
        do {
            try model.rosterStore.addMember(
                to: rosterID,
                displayName: manualName,
                email: manualEmail,
                contactIdentifier: nil
            )
            manualName = ""
            manualEmail = ""
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}

/// Bulk add from a pasted comma/newline-separated address list. Entries may
/// be bare addresses or `Firstname Lastname <email@host>`; parsing lives in
/// EmailListParser and is covered by unit tests.
private struct PasteSheet: View {
    let model: AppModel
    let rosterID: UUID

    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var parsed: EmailListParser.Result { EmailListParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste invitee list").font(.title3.bold())
            // Text(verbatim:) — a plain Text("…") literal parses markdown,
            // which turns <email@host> into an autolink and eats the brackets.
            Text(verbatim: "Comma- or newline-separated. Bare addresses or \"Firstname Lastname <email@host>\".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            let result = parsed
            HStack {
                if result.entries.isEmpty && result.invalid.isEmpty {
                    Text("Paste a list above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(result.entries.count) addable, \(result.invalid.count) invalid")
                        .font(.caption)
                        .foregroundStyle(result.invalid.isEmpty ? Color(nsColor: .secondaryLabelColor) : .orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add \(result.entries.count)") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result.entries.isEmpty)
            }
            if !result.invalid.isEmpty {
                Text(verbatim: "Invalid: \(result.invalid.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(result.invalid.joined(separator: ", "))
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        let result = parsed
        do {
            let outcome = try model.rosterStore.addParsedMembers(to: rosterID, entries: result.entries)
            var parts: [String] = ["Added \(outcome.added) member\(outcome.added == 1 ? "" : "s")."]
            if !outcome.duplicates.isEmpty {
                parts.append("Skipped duplicates: \(outcome.duplicates.joined(separator: ", "))")
            }
            if !result.invalid.isEmpty {
                parts.append("Skipped invalid: \(result.invalid.joined(separator: ", "))")
            }
            model.alertMessage = parts.joined(separator: " ")
            dismiss()
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}
