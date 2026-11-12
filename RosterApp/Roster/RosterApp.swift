//
//  RosterApp.swift
//  Roster
//
//  Created by Arthur Rosa on 2026-11-11.
//

import SwiftUI

@main
struct RosterApp: App {
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
    }
}
