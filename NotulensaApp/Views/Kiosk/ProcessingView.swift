import SwiftUI

/// Shown while the printable photo, GIF, and live photo are being built.
struct ProcessingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.extraLarge)
                .tint(.white)
            Text(message)
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
    }
}
