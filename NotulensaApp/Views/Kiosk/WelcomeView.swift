import SwiftUI

/// Kiosk welcome screen: background photo + Start Photo Session + Gallery buttons,
/// positioned exactly as configured in the event setup wizard.
struct WelcomeView: View {
    @Bindable var event: Event
    let onStart: () -> Void
    let onGallery: () -> Void

    var body: some View {
        WelcomeScreenLayoutView(event: event, isEditable: false, onStart: onStart, onGallery: onGallery)
            .ignoresSafeArea()
    }
}
