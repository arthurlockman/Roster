import SwiftUI

/// First-run walkthrough. Shows once per install (persisted in
/// UserDefaults); reopenable any time from the Rosters header button.
struct OnboardingSheet: View {
    let onFinish: () -> Void

    @State private var step = 0

    private struct Step {
        let symbol: String
        let title: String
        let paragraphs: [String]
    }

    private let steps: [Step] = [
        Step(symbol: "person.3.sequence", title: "Welcome to Roster", paragraphs: [
            "Roster keeps named sets of invitees — families, teams, standing meeting groups — and adds them to calendar events with one drag.",
            "You build the lists; Calendar stays the source of truth for events and guests.",
        ]),
        Step(symbol: "person.badge.plus", title: "Build a roster", paragraphs: [
            "Create a roster, add people from your contacts, or type any email address manually — no saved contact required.",
            "Give each card its own emoji and background color from the ⋯ menu, and drag-reorder the list by dropping cards between each other.",
        ]),
        Step(symbol: "calendar.badge.plus", title: "Drop onto an event", paragraphs: [
            "Pick the calendars you care about and navigate to a day, then drag a roster card onto an event.",
            "Roster compares the event's current invitees with your roster, shows who is missing for confirmation, and adds only those. It never removes or edits existing guests.",
        ]),
        Step(symbol: "lock.shield", title: "Permissions", paragraphs: [
            "Roster asks for Calendar access (events and invitees), Contacts access (finding addresses), and Automation consent (adding invitees through Calendar.app — the only native way).",
            "A denied permission is shown as an actionable state with a shortcut to System Settings, never as an empty day. Company-directory people must be saved into Contacts.app first; directories aren't searchable from third-party apps.",
        ]),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: steps[step].symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text(steps[step].title)
                .font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps[step].paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 36)
            Spacer(minLength: 12)
            HStack {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .keyboardShortcut(.cancelAction)
                }
                if step < steps.count - 1 {
                    Button("Next") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 430)
    }
}
