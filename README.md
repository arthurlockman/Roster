# Roster

Roster is a macOS app for managing invitee sets and filling out event invitations. Build a roster of people once, then drag it onto any event in your calendar to see who's missing and add them with one confirmation.

## Features

- **Rosters** — named, editable invitee sets stored in one `rosters.json` file (by default in `~/Library/Application Support/RosterApp/`). Members are snapshotted by email at the time you add them, so later edits in Contacts never silently change who gets invited.
- **Shared storage folder** — move the library to any folder (Dropbox, Box, iCloud Drive, or local) via the **Storage…** button in the roster pane. Everyone with access to that folder sees the same rosters; joining a populated folder adopts its `rosters.json`, and your previous file is left untouched. Edits are sequential: each save checks the file and refuses to apply when it changed elsewhere, so reload and retry. Sync providers may still create conflict copies when offline edits collide — Roster does not merge them.
- **Calendar day view** — pick which calendars to read, navigate previous/today/next, and see events sorted all-day-first with their current invitee counts.
- **Drag-to-event preview** — dragging a roster onto an event shows exactly which roster members are *not* yet invited before anything is written. If everyone is already there, it says so.
- **Add-only invitee addition** — confirming adds only the missing addresses. Existing invitees (accepted, declined, tentative, or pending) are never touched, removed, or re-RSVP'd.
- **Recurring-event safety** — recurring events are labeled "Add to recurring series (edited occurrences may differ)" and operate on the whole series, never a single silently-edited instance.
- **Contacts integration** — search your saved and synced contacts across all accounts. For corporate directory (GAL/LDAP) results, which Contacts.framework can't query directly, Roster shows how to save the result into Contacts.app first and then find it here.

## How attendee additions work

EventKit can read events and attendees but [cannot add attendees](https://developer.apple.com/documentation/eventkit/ekcalendaritem/attendees). Roster therefore reads everything through EventKit, and performs the one write it needs — appending a missing invitee — through Calendar.app automation (a bundled JavaScript-for-Automation script run out-of-process). The drag preview is answered entirely in-process from EventKit, so it appears instantly; while you review, a read-only locate pass resolves the event once inside Calendar, letting the write itself resolve the same event by id in well under a second. Before any write, Roster re-resolves the target event inside Calendar and verifies the event identity, attendee list, and recurrence scope still match what you reviewed. If it can't match the event safely, it refuses and tells you — it never guesses by title or date.

## Permissions

On first use, macOS asks for three separate grants:

| Permission | Why |
|---|---|
| **Calendars (full access)** | Read events, invitees, and calendar lists |
| **Contacts** | Search names and email addresses for roster members |
| **Automation → Calendar** | Add confirmed missing invitees to events |

Denying any of them is safe: stored rosters stay visible and editable, and Roster points you to System Settings instead of pretending nothing is wrong.

## Requirements

- macOS 26.0 or later
- Calendar.app configured with at least one writable, invitation-capable calendar (iCloud/Exchange/CalDAV). Local "On My Mac" calendars cannot hold attendees; Roster reports this rather than failing silently.

## Install

Download `Roster-x.y.z.zip` from [Releases](https://github.com/arthurlockman/Roster/releases), unzip, and move **Roster.app** to `/Applications`. The app is Developer-ID signed, notarized, and stapled, so Gatekeeper opens it without warnings.

Roster self-updates via [Sparkle](https://sparkle-project.org). It checks [the appcast](https://arthurlockman.github.io/Roster/appcast.xml) and offers updates automatically; you can also use **Roster → Check for Updates…**.

## Building from source

Requires Xcode 27.2 or later.

```
git clone https://github.com/arthurlockman/Roster.git
cd Roster
open RosterApp/Roster.xcodeproj
```

Build and test with `⌘U` (Swift Testing suite) or:

```
xcodebuild -project RosterApp/Roster.xcodeproj -scheme Roster test
```

## Releasing

`.github/workflows/release.yml` runs on a `v*` tag push or a manual dispatch with a version string. It archives, exports with Developer ID signing, notarizes, staples, publishes the GitHub release, signs the Sparkle update, and appends the appcast item. Signing/notarization secrets are optional: without them the workflow still builds and publishes a clearly-labeled unsigned test prerelease.

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_P12_BASE64` / `DEVELOPER_ID_P12_PASSWORD` | Developer ID Application certificate |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID |
| `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` | App Store Connect API key for notarization |
| `SPARKLE_PRIVATE_KEY` | EdDSA key for signing Sparkle updates |

## Privacy

Roster makes no network requests of its own. Everything it knows — your rosters and calendar selection — lives on your Mac. Calendar and Contacts access uses Apple's system frameworks under your account's existing authentication.
