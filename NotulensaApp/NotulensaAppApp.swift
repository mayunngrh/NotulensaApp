//
//  NotulensaAppApp.swift
//  NotulensaApp
//
//  Created by Mayun Suryatama on 15/07/26.
//

import SwiftUI
import SwiftData

@main
struct NotulensaAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Event.self, PhotoTemplate.self, PhotoSlot.self, CompositedPhoto.self])
    }
}
