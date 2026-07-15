import SwiftUI

/// Step 4 of event setup: countdown timing, review duration, GIF, and live photo settings.
struct CaptureSettingsView: View {
    @Bindable var event: Event

    var body: some View {
        Form {
            Section {
                Stepper("First photo: \(event.countdownFirst)s", value: $event.countdownFirst, in: 1...15)
                Stepper("Other photos: \(event.countdownOthers)s", value: $event.countdownOthers, in: 1...15)
            } header: {
                Text("Countdown")
            } footer: {
                Text("Seconds shown before each shot. The first photo often gets extra time to get ready.")
            }

            Section {
                Stepper("Display each photo for \(event.reviewSeconds)s", value: $event.reviewSeconds, in: 1...15)
            } header: {
                Text("Review")
            } footer: {
                Text("How long a captured photo is shown before auto-advancing to the next shot (Retake/Next still work anytime).")
            }

            Section {
                Stepper("Width: \(event.gifWidth)px", value: $event.gifWidth, in: 240...1080, step: 60)
                Stepper("Frame duration: \(event.gifFrameSeconds.formatted(.number.precision(.fractionLength(1))))s", value: $event.gifFrameSeconds, in: 0.2...2.0, step: 0.1)
            } header: {
                Text("GIF")
            } footer: {
                Text("The GIF cycles through each captured photo at this size and speed.")
            }

            Section {
                Stepper("Loop \(event.livePhotoLoops) time(s)", value: $event.livePhotoLoops, in: 1...6)
            } header: {
                Text("Live Photo")
            } footer: {
                Text("Each photo's short recorded clip is composited into the template and looped this many times.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture Settings")
    }
}
