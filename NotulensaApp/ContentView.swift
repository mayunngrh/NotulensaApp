//
//  ContentView.swift
//  NotulensaApp
//
//  Created by Mayun Suryatama on 15/07/26.
//

import SwiftUI

@Observable
final class AppRouter {
    /// When set, the app is running an event in kiosk mode.
    var runningEvent: Event?
}

struct ContentView: View {
    @State private var router = AppRouter()

    var body: some View {
        Group {
            if let event = router.runningEvent {
                KioskView(event: event)
            } else {
                DashboardView()
            }
        }
        .environment(router)
    }
}

#Preview {
    ContentView()
}
