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
            rosterStore: RosterStore(),
            contactsService: ContactsService(),
            calendarService: CalendarService(),
            automation: CalendarAutomation.shared
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
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
