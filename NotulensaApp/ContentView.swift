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
    @State private var canon = CanonCameraService.shared

    var body: some View {
        Group {
            if let event = router.runningEvent {
                KioskView(event: event)
            } else {
                DashboardView()
            }
        }
        .environment(router)
        .task {
            canon.startMonitoring()
        }
        .overlay(alignment: .top) {
            if let toast = canon.toast {
                Label(toast, systemImage: "camera.badge.ellipsis")
                    .font(.callout.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8)
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: canon.toast)
    }
}

#Preview {
    ContentView()
}
