//
//  RosterApp.swift
//  Roster
//
//  Created by Arthur Rosa on 2026-11-11.
//

import Sparkle
import SwiftUI

@main
struct RosterApp: App {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @State private var model: AppModel

    init() {
        model = AppModel(
            rosterStore: AppModel.makeRosterStore(),
            contactsService: ContactsService(),
            calendarService: CalendarService(),
            automation: CalendarAutomation.shared
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    guard updaterController.updater.automaticallyChecksForUpdates else { return }
                    // Sparkle's startup schedules its own check cycle and
                    // rejects a concurrent call with .sessionInProgress, so
                    // wait until it can accept one. Without this, the launch
                    // check always loses that race and the app never checks
                    // on open until the scheduled interval elapses.
                    let updater = updaterController.updater
                    for _ in 0..<100 {
                        if updater.canCheckForUpdates { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard updater.canCheckForUpdates else { return }
                    updater.checkForUpdatesInBackground()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
