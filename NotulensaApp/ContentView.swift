//
import Combine
//  ContentView.swift
//  NotulensaApp
//
//  Created by Mayun Suryatama on 15/07/26.
//

import SwiftUI

final class AppRouter: ObservableObject {
    /// When set, the app is running an event in kiosk mode.
    @Published var runningEvent: Event?
}

struct ContentView: View {
    @StateObject private var router = AppRouter()
    @StateObject private var store = PhotoboothStore.shared
    @ObservedObject private var canon = CanonCameraService.shared
    @ObservedObject private var sony = SonyCameraService.shared

    var body: some View {
        Group {
            if let event = router.runningEvent {
                KioskView(event: event)
            } else {
                DashboardView()
            }
        }
        .environmentObject(router)
        .environmentObject(store)
        .task {
            canon.startMonitoring()
            sony.startMonitoring()
        }
        .overlay(alignment: .top) {
            if let toast = canon.toast ?? sony.toast {
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
        .animation(.spring(duration: 0.4), value: sony.toast)
    }
}
